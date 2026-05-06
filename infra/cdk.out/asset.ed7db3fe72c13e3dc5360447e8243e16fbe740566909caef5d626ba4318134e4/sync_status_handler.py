"""
sync_status_handler.py — Lambda that returns per-photo cloud sync status.

Endpoint: GET /sync/status/{canonicalId} (via API Gateway)
Called by: Swift SyncClient (sync status badge icons in LibraryView)

Architecture:
    - Client sends canonicalId as a path parameter.
    - Lambda checks if proxy exists in S3 (head_object on proxies/{canonicalId}).
    - Lambda counts thread entries in DynamoDB for this photo.
    - Returns PhotoSyncStatus per the OpenAPI spec schema.

Environment variables (injected by CDK stack):
    BUCKET_NAME  — S3 bucket for all assets
    TABLE_NAME   — DynamoDB thread table name

IAM: Lambda execution role needs:
    s3:HeadObject on bucket/proxies/*
    dynamodb:Query on the thread table
"""

import json
import os
import boto3
import logging
from botocore.exceptions import ClientError
from boto3.dynamodb.conditions import Key

logger = logging.getLogger()
logger.setLevel(logging.INFO)

BUCKET_NAME = os.environ.get("BUCKET_NAME", "")
TABLE_NAME = os.environ.get("TABLE_NAME", "")

s3_client = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")


def handler(event: dict, context) -> dict:
    """
    Entry point for API Gateway proxy integration.

    GET /sync/status/{canonicalId}

    Returns:
        200 with PhotoSyncStatus JSON
        400 for missing canonicalId
        404 if photo has never been synced (no proxy, no threads)
        500 for unexpected errors
    """
    try:
        path_params = event.get("pathParameters") or {}
        canonical_id = path_params.get("canonicalId")

        if not canonical_id:
            return _error_response(400, "Missing canonicalId path parameter")

        if not BUCKET_NAME or not TABLE_NAME:
            return _error_response(500, "BUCKET_NAME or TABLE_NAME environment variable is not set")

        # Check if proxy exists in S3
        proxy_status = "missing"
        proxy_synced_at = None
        try:
            proxy_key = f"proxies/{canonical_id}"
            head_resp = s3_client.head_object(Bucket=BUCKET_NAME, Key=proxy_key)
            proxy_status = "synced"
            last_modified = head_resp.get("LastModified")
            if last_modified:
                proxy_synced_at = int(last_modified.timestamp())
        except ClientError as e:
            if e.response["Error"]["Code"] == "404":
                proxy_status = "missing"
            else:
                logger.warning("S3 head_object error for %s: %s", canonical_id, e)
                proxy_status = "missing"

        # Count thread entries in DynamoDB
        table = dynamodb.Table(TABLE_NAME)
        thread_count = 0
        last_thread_time = None
        try:
            response = table.query(
                KeyConditionExpression=Key("threadRootId").eq(canonical_id),
                Select="COUNT",
            )
            thread_count = response.get("Count", 0)

            # If there are entries, get the latest timestamp for lastSyncTime
            if thread_count > 0:
                latest_resp = table.query(
                    KeyConditionExpression=Key("threadRootId").eq(canonical_id),
                    ScanIndexForward=False,
                    Limit=1,
                )
                items = latest_resp.get("Items", [])
                if items:
                    last_thread_time = int(items[0].get("timestamp", 0))
        except ClientError as e:
            logger.warning("DynamoDB query error for %s: %s", canonical_id, e)

        # Determine overall status
        has_proxy = proxy_status == "synced"
        has_threads = thread_count > 0

        if not has_proxy and not has_threads:
            return _error_response(404, f"Photo '{canonical_id}' has never been synced")

        if has_proxy and has_threads:
            overall_status = "synced"
        else:
            overall_status = "synced"  # partial sync is still "synced"

        # Determine lastSyncTime (most recent of proxy or thread)
        last_sync_time = None
        if proxy_synced_at and last_thread_time:
            last_sync_time = max(proxy_synced_at, last_thread_time)
        elif proxy_synced_at:
            last_sync_time = proxy_synced_at
        elif last_thread_time:
            last_sync_time = last_thread_time

        body = {
            "canonicalId": canonical_id,
            "status": overall_status,
            "proxyStatus": proxy_status,
            "threadCount": thread_count,
            "lastSyncTime": last_sync_time,
        }

        logger.info(
            "Sync status for %s: proxy=%s threads=%d lastSync=%s",
            canonical_id, proxy_status, thread_count, last_sync_time,
        )

        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(body),
        }

    except Exception as exc:
        logger.error("Unexpected error checking sync status: %s", exc, exc_info=True)
        return _error_response(500, "Internal error checking sync status")


def _error_response(status_code: int, message: str) -> dict:
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"error": message}),
    }
