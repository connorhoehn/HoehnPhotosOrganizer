"""
restore_manifest_handler.py — Lambda that returns a restore manifest of all synced assets.

Endpoint: GET /restore/manifest (via API Gateway)
Called by: Swift SyncClient (restore flow, Plan 04-04)

Architecture:
    - Lists S3 objects under proxies/ and curves/ prefixes.
    - Queries DynamoDB for catalog exports (threadRootId = "__catalog_export__").
    - Returns RestoreManifest per the OpenAPI spec schema.
    - Paginated with nextToken for large asset sets.

Environment variables (injected by CDK stack):
    BUCKET_NAME  — S3 bucket for all assets
    TABLE_NAME   — DynamoDB thread table name

IAM: Lambda execution role needs:
    s3:ListBucket on the bucket
    dynamodb:Query on the thread table
"""

import json
import os
import base64
import time
import boto3
import logging
from botocore.exceptions import ClientError
from boto3.dynamodb.conditions import Key

logger = logging.getLogger()
logger.setLevel(logging.INFO)

BUCKET_NAME = os.environ.get("BUCKET_NAME", "")
TABLE_NAME = os.environ.get("TABLE_NAME", "")

CATALOG_EXPORT_THREAD_ROOT = "__catalog_export__"

# Maximum objects to return per page
PAGE_SIZE = 100

s3_client = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")


def handler(event: dict, context) -> dict:
    """
    Entry point for API Gateway proxy integration.

    GET /restore/manifest?assetType=all&nextToken=...&since=...

    Returns:
        200 with RestoreManifest JSON
        500 for unexpected errors
    """
    try:
        params = event.get("queryStringParameters") or {}
        asset_type = params.get("assetType", "all")
        next_token_raw = params.get("nextToken")
        since = params.get("since")
        since_ts = int(since) if since else None

        if not BUCKET_NAME or not TABLE_NAME:
            return _error_response(500, "BUCKET_NAME or TABLE_NAME environment variable is not set")

        # Decode pagination token
        pagination = _decode_token(next_token_raw) if next_token_raw else {}

        proxies = []
        curves = []
        threads = []
        next_pagination = {}

        # Fetch proxies from S3
        if asset_type in ("all", "proxy"):
            proxy_token = pagination.get("proxyContinuation")
            proxy_result = _list_s3_objects("proxies/", proxy_token, since_ts)
            proxies = proxy_result["items"]
            if proxy_result.get("continuation"):
                next_pagination["proxyContinuation"] = proxy_result["continuation"]

        # Fetch curves from S3
        if asset_type in ("all", "curve"):
            curve_token = pagination.get("curveContinuation")
            curve_result = _list_s3_objects("curves/", curve_token, since_ts)
            curves = curve_result["items"]
            if curve_result.get("continuation"):
                next_pagination["curveContinuation"] = curve_result["continuation"]

        # Fetch thread entries from DynamoDB (catalog exports)
        if asset_type in ("all", "thread"):
            thread_result = _query_catalog_exports(since_ts)
            threads = thread_result

        # Build next token
        next_token = _encode_token(next_pagination) if next_pagination else None

        body = {
            "proxies": proxies,
            "curves": curves,
            "threads": threads,
            "generatedAt": int(time.time()),
            "nextToken": next_token,
            "totalPhotos": len(set(
                [p["canonicalId"] for p in proxies] +
                [c["photoId"] for c in curves]
            )),
        }

        logger.info(
            "Restore manifest: %d proxies, %d curves, %d threads, nextToken=%s",
            len(proxies), len(curves), len(threads), "yes" if next_token else "no",
        )

        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(body),
        }

    except Exception as exc:
        logger.error("Unexpected error building restore manifest: %s", exc, exc_info=True)
        return _error_response(500, "Internal error building restore manifest")


def _list_s3_objects(prefix: str, continuation_token: str | None, since_ts: int | None) -> dict:
    """List S3 objects under a prefix, returning parsed asset entries."""
    list_kwargs = {
        "Bucket": BUCKET_NAME,
        "Prefix": prefix,
        "MaxKeys": PAGE_SIZE,
    }
    if continuation_token:
        list_kwargs["ContinuationToken"] = continuation_token

    response = s3_client.list_objects_v2(**list_kwargs)
    items = []

    for obj in response.get("Contents", []):
        key = obj["Key"]
        last_modified = obj.get("LastModified")
        synced_at = int(last_modified.timestamp()) if last_modified else None

        # Apply since filter
        if since_ts and synced_at and synced_at <= since_ts:
            continue

        if prefix == "proxies/":
            # proxies/IMG_1234.CR3.jpg -> IMG_1234.CR3
            filename = key[len("proxies/"):]
            canonical_id = filename.rsplit(".", 1)[0] if "." in filename else filename
            items.append({
                "canonicalId": canonical_id,
                "s3Key": key,
                "syncedAt": synced_at,
            })
        elif prefix == "curves/":
            # curves/IMG_1234.CR3_B8F2A3D1-1234.acv
            filename = key[len("curves/"):]
            parts = filename.rsplit("_", 1)
            photo_id = parts[0] if len(parts) > 1 else filename
            attempt_part = parts[1] if len(parts) > 1 else ""
            attempt_id = attempt_part.rsplit(".", 1)[0] if "." in attempt_part else attempt_part
            items.append({
                "photoId": photo_id,
                "attemptId": attempt_id,
                "s3Key": key,
                "syncedAt": synced_at,
            })

    result = {"items": items}
    if response.get("IsTruncated"):
        result["continuation"] = response.get("NextContinuationToken")

    return result


def _query_catalog_exports(since_ts: int | None) -> list:
    """Query DynamoDB for catalog export records."""
    table = dynamodb.Table(TABLE_NAME)

    query_kwargs = {
        "KeyConditionExpression": Key("threadRootId").eq(CATALOG_EXPORT_THREAD_ROOT),
        "ScanIndexForward": False,  # newest first
    }

    try:
        response = table.query(**query_kwargs)
        entries = []
        for item in response.get("Items", []):
            exported_at = item.get("exportedAt", "")
            entries.append({
                "threadRootId": CATALOG_EXPORT_THREAD_ROOT,
                "entryId": item.get("versionId", ""),
                "s3Key": item.get("s3Key", ""),
                "exportedAt": exported_at,
                "fileSize": int(item.get("fileSize", 0)),
                "checksum": item.get("checksum", ""),
            })
        return entries
    except ClientError as e:
        logger.warning("DynamoDB query error for catalog exports: %s", e)
        return []


def _decode_token(token: str) -> dict:
    """Decode a base64-encoded JSON pagination token."""
    try:
        return json.loads(base64.b64decode(token).decode("utf-8"))
    except Exception:
        return {}


def _encode_token(data: dict) -> str:
    """Encode a pagination state dict as a base64 JSON string."""
    return base64.b64encode(json.dumps(data).encode("utf-8")).decode("utf-8")


def _error_response(status_code: int, message: str) -> dict:
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"error": message}),
    }
