"""
catalog_export_handler.py — Lambda triggered to register catalog export metadata in DynamoDB.

Endpoint: POST /sync/catalog (via API Gateway)
Called by: CatalogExportService.swift after uploading .sql.gz to S3

Purpose:
    After the Swift client uploads a .sql.gz file to S3, it calls this endpoint to
    register the export in DynamoDB. This lets the restore manifest API (/restore/manifest)
    return the latest catalog export key and version ID without scanning S3.

Architecture:
    - Swift client uploads .sql.gz directly to S3 via presigned URL (no Lambda involvement).
    - Swift client then calls POST /sync/catalog with {s3Key, fileSize, checksum}.
    - This Lambda writes a record to DynamoDB with the export metadata.
    - Restore manifest queries DynamoDB for the latest export record.

Request body (JSON):
    {
        "s3Key": "catalog/exports/2026-03-15T22-00-00Z.sql.gz",
        "fileSize": 12345,
        "checksum": "sha256hex...",
        "exportedAt": "2026-03-15T22:00:00Z"  (ISO8601, optional — defaults to now)
    }

Response:
    200 {recorded: true, versionId: "dynamodb-record-id"}
    400 {error: "..."}
    500 {error: "..."}

Environment variables:
    BUCKET_NAME  — S3 bucket (used to validate key prefix)
    TABLE_NAME   — DynamoDB thread table for catalog export records
"""

import json
import os
import uuid
import boto3
import logging
from datetime import datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

BUCKET_NAME = os.environ.get("BUCKET_NAME", "")
TABLE_NAME = os.environ.get("TABLE_NAME", "")

# Catalog export records use a special partition key so they're distinct from thread entries.
CATALOG_EXPORT_THREAD_ROOT = "__catalog_export__"

dynamodb = boto3.resource("dynamodb")


def handler(event: dict, context) -> dict:
    """
    Entry point for API Gateway proxy integration.

    Records a catalog export event in DynamoDB so the restore manifest can find
    the latest export without scanning S3.
    """
    try:
        body_str = event.get("body") or "{}"
        body = json.loads(body_str)

        s3_key = body.get("s3Key", "")
        file_size = body.get("fileSize", 0)
        checksum = body.get("checksum", "")
        exported_at = body.get("exportedAt") or datetime.now(tz=timezone.utc).isoformat()

        # Validate
        if not s3_key or not s3_key.startswith("catalog/exports/"):
            return _error_response(400, "Missing or invalid s3Key — must start with catalog/exports/")
        if not checksum:
            return _error_response(400, "Missing required field: checksum")
        if not TABLE_NAME:
            return _error_response(500, "TABLE_NAME environment variable is not set")

        # Write to DynamoDB
        version_id = str(uuid.uuid4())
        table = dynamodb.Table(TABLE_NAME)

        item = {
            "threadRootId": CATALOG_EXPORT_THREAD_ROOT,
            "sortKey": f"{exported_at}#{version_id}",
            "entryType": "catalog_export",
            "s3Key": s3_key,
            "fileSize": file_size,
            "checksum": checksum,
            "exportedAt": exported_at,
            "versionId": version_id,
        }

        table.put_item(Item=item)

        logger.info("Recorded catalog export: s3Key=%s versionId=%s", s3_key, version_id)

        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"recorded": True, "versionId": version_id}),
        }

    except json.JSONDecodeError as exc:
        return _error_response(400, f"Invalid JSON body: {exc}")
    except Exception as exc:
        logger.error("Unexpected error recording catalog export: %s", exc, exc_info=True)
        return _error_response(500, "Internal error recording catalog export")


def _error_response(status_code: int, message: str) -> dict:
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"error": message}),
    }
