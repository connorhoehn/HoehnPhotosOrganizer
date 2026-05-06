"""
catalog_sync_handler.py — Lambda that batch-upserts catalog entities to DynamoDB.

Endpoint: POST /sync/catalog-batch (via API Gateway)
Called by: CatalogSyncClient.swift (pushCatalogBatch)

Architecture:
    - Client sends {"items": [{"entityType": "PHOTO", "entityId": "...", "data": {...}}, ...]}
    - Lambda extracts userId from Cognito JWT claims (event.requestContext.authorizer).
    - Items are chunked into DynamoDB BatchWriteItem calls (25-item hard limit).
    - Each item is stored with PK=userId, SK=entityType#entityId.
    - updatedAt is set to current epoch for GSI1 incremental sync queries.
    - Returns {"syncTimestamp": epoch, "writtenCount": N} on success.

DynamoDB table: HoehnPhotos-Catalog (controlled by CATALOG_TABLE_NAME env var)
    PK: userId    — Cognito sub
    SK: sk        — "PHOTO#uuid", "JOB#uuid", "PERSON#uuid", etc.

IAM: Lambda execution role needs dynamodb:BatchWriteItem on the catalog table.

Environment variables (injected by CDK stack):
    CATALOG_TABLE_NAME — DynamoDB catalog table name
"""

import json
import os
import time
import logging
import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

TABLE_NAME = os.environ.get("CATALOG_TABLE_NAME", "")

VALID_ENTITY_TYPES = {"PHOTO", "JOB", "PERSON", "FACE", "REVISION"}

dynamodb = boto3.resource("dynamodb")


def handler(event: dict, context) -> dict:
    """
    Entry point for API Gateway proxy integration.

    POST /sync/catalog-batch
    Body: {"items": [{"entityType": "PHOTO", "entityId": "...", "data": {...}}, ...]}

    Returns:
        200 with {"syncTimestamp": <epoch>, "writtenCount": N}
        400 with {"error": "..."} for invalid input
        500/503 with {"error": "...", "retryable": bool} for AWS errors
    """
    try:
        if not TABLE_NAME:
            return _response(500, {"error": "CATALOG_TABLE_NAME environment variable is not set"})

        # Extract userId from Cognito JWT claims
        user_id = _extract_user_id(event)
        if not user_id:
            return _response(400, {"error": "Missing userId — Cognito authorizer not configured or sub claim absent"})

        body = json.loads(event.get("body") or "{}")
        items = body.get("items", [])

        if not items:
            return _response(400, {"error": "No items provided"})

        # Validate all items before writing
        for i, item in enumerate(items):
            entity_type = item.get("entityType", "")
            entity_id = item.get("entityId", "")
            if entity_type not in VALID_ENTITY_TYPES:
                return _response(400, {
                    "error": f"Item {i}: invalid entityType '{entity_type}'. Must be one of {sorted(VALID_ENTITY_TYPES)}"
                })
            if not entity_id:
                return _response(400, {"error": f"Item {i}: missing entityId"})

        now = int(time.time())
        table = dynamodb.Table(TABLE_NAME)
        written = 0

        # DynamoDB BatchWriteItem max 25 items per call
        for i in range(0, len(items), 25):
            batch = items[i:i + 25]
            with table.batch_writer() as writer:
                for item in batch:
                    entity_type = item["entityType"]
                    entity_id = item["entityId"]
                    data = item.get("data") or {}

                    db_item = {
                        "userId": user_id,
                        "sk": f"{entity_type}#{entity_id}",
                        "entityType": entity_type,
                        "entityId": entity_id,
                        "updatedAt": now,
                        "data": json.dumps(data),
                    }

                    # Set canonicalName for GSI2 lookups (PHOTO entities only)
                    canonical_name = data.get("canonicalName")
                    if canonical_name:
                        db_item["canonicalName"] = canonical_name

                    writer.put_item(Item=db_item)
                    written += 1

        logger.info("Batch upsert: userId=%s writtenCount=%d", user_id, written)

        return _response(200, {
            "syncTimestamp": now,
            "writtenCount": written,
        })

    except json.JSONDecodeError as exc:
        return _response(400, {"error": f"Invalid JSON body: {exc}"})
    except ClientError as e:
        error_code = e.response["Error"]["Code"]
        if error_code in ("ProvisionedThroughputExceededException", "ThrottlingException"):
            return _response(503, {"error": "DynamoDB throttled", "retryable": True})
        logger.error("DynamoDB ClientError: %s", e, exc_info=True)
        return _response(500, {"error": str(e), "retryable": False})
    except Exception as e:
        logger.error("Unexpected error in catalog batch sync: %s", e, exc_info=True)
        return _response(500, {"error": "Internal error processing catalog batch", "retryable": False})


def _extract_user_id(event: dict) -> str | None:
    """Extract Cognito user sub from JWT authorizer claims."""
    request_context = event.get("requestContext") or {}
    authorizer = request_context.get("authorizer") or {}
    claims = authorizer.get("claims") or {}
    return claims.get("sub")


def _response(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }
