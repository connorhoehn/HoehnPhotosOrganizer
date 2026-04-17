"""
catalog_query_handler.py — Lambda that queries catalog entities for incremental sync.

Endpoint: GET /sync/catalog (via API Gateway)
Called by: CatalogSyncClient.swift (pullCatalogChanges)

Architecture:
    - Client sends query params: since (epoch), entityType (optional), limit, nextToken.
    - Lambda extracts userId from Cognito JWT claims.
    - Queries GSI1 (byUpdatedAt) with userId partition key, updatedAt > since.
    - Optionally filters by entityType (server-side filter expression).
    - Supports pagination via nextToken (base64-encoded ExclusiveStartKey).
    - Returns {"items": [...], "nextToken": "...", "syncTimestamp": epoch}.

DynamoDB table: HoehnPhotos-Catalog (controlled by CATALOG_TABLE_NAME env var)
    GSI1: byUpdatedAt — PK: userId, SK: updatedAt (NUMBER)

IAM: Lambda execution role needs dynamodb:Query on the catalog table and GSI1.

Environment variables (injected by CDK stack):
    CATALOG_TABLE_NAME — DynamoDB catalog table name
"""

import json
import os
import time
import base64
import logging
import boto3
from boto3.dynamodb.conditions import Key, Attr
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

TABLE_NAME = os.environ.get("CATALOG_TABLE_NAME", "")

VALID_ENTITY_TYPES = {"PHOTO", "JOB", "PERSON", "FACE", "REVISION"}

dynamodb = boto3.resource("dynamodb")


def handler(event: dict, context) -> dict:
    """
    Entry point for API Gateway proxy integration.

    GET /sync/catalog?since=1710000000&entityType=PHOTO&limit=100&nextToken=...

    Returns:
        200 with {"items": [...], "nextToken": "...|null", "syncTimestamp": <epoch>}
        400 with {"error": "..."} for invalid input
        500 with {"error": "..."}
    """
    try:
        if not TABLE_NAME:
            return _response(500, {"error": "CATALOG_TABLE_NAME environment variable is not set"})

        # Extract userId from Cognito JWT claims
        user_id = _extract_user_id(event)
        if not user_id:
            return _response(400, {"error": "Missing userId — Cognito authorizer not configured or sub claim absent"})

        params = event.get("queryStringParameters") or {}
        since = int(params.get("since", "0"))
        entity_type = params.get("entityType")
        limit = min(int(params.get("limit", "100")), 1000)  # Cap at 1000
        next_token = params.get("nextToken")

        # Validate entityType filter if provided
        if entity_type and entity_type not in VALID_ENTITY_TYPES:
            return _response(400, {
                "error": f"Invalid entityType '{entity_type}'. Must be one of {sorted(VALID_ENTITY_TYPES)}"
            })

        table = dynamodb.Table(TABLE_NAME)

        # Build query kwargs for GSI1 (byUpdatedAt)
        query_kwargs = {
            "IndexName": "byUpdatedAt",
            "KeyConditionExpression": Key("userId").eq(user_id) & Key("updatedAt").gt(since),
            "ScanIndexForward": True,  # Ascending by updatedAt
            "Limit": limit,
        }

        # Optional entity type filter (server-side)
        if entity_type:
            query_kwargs["FilterExpression"] = Attr("entityType").eq(entity_type)

        # Pagination: decode nextToken into ExclusiveStartKey
        if next_token:
            try:
                decoded = base64.b64decode(next_token)
                query_kwargs["ExclusiveStartKey"] = json.loads(decoded)
            except Exception:
                return _response(400, {"error": "Invalid nextToken"})

        response = table.query(**query_kwargs)

        # Build result items
        items = []
        for db_item in response.get("Items", []):
            item = {
                "entityType": db_item.get("entityType"),
                "entityId": db_item.get("entityId"),
                "updatedAt": int(db_item.get("updatedAt", 0)),
                "data": json.loads(db_item.get("data") or "{}"),
            }
            # Include deletedAt if present (soft-deleted items)
            deleted_at = db_item.get("deletedAt")
            if deleted_at is not None:
                item["deletedAt"] = int(deleted_at)
            items.append(item)

        # Encode LastEvaluatedKey as nextToken for pagination
        result_next_token = None
        last_key = response.get("LastEvaluatedKey")
        if last_key:
            result_next_token = base64.b64encode(json.dumps(last_key).encode()).decode()

        sync_timestamp = int(time.time())

        logger.info(
            "Catalog query: userId=%s since=%d entityType=%s returned=%d hasMore=%s",
            user_id, since, entity_type or "ALL", len(items), bool(last_key),
        )

        return _response(200, {
            "items": items,
            "nextToken": result_next_token,
            "syncTimestamp": sync_timestamp,
        })

    except ClientError as e:
        logger.error("DynamoDB ClientError: %s", e, exc_info=True)
        return _response(500, {"error": str(e)})
    except Exception as e:
        logger.error("Unexpected error in catalog query: %s", e, exc_info=True)
        return _response(500, {"error": "Internal error querying catalog"})


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
