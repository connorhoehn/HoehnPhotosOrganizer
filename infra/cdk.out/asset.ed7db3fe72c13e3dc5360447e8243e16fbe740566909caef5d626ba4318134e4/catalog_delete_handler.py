"""
catalog_delete_handler.py — Lambda that soft-deletes catalog entities in DynamoDB.

Endpoint: DELETE /sync/catalog/{entityType}/{entityId} (via API Gateway)
Called by: CatalogSyncClient.swift (deleteCatalogEntity)

Architecture:
    - Client sends entityType and entityId as path parameters.
    - Lambda extracts userId from Cognito JWT claims.
    - Performs a soft-delete by setting `deletedAt` attribute on the item.
    - The item remains queryable via GSI1 so sync clients see the deletion.
    - Returns {"deleted": true, "syncTimestamp": epoch} on success.

DynamoDB table: HoehnPhotos-Catalog (controlled by CATALOG_TABLE_NAME env var)
    PK: userId    — Cognito sub
    SK: sk        — "PHOTO#uuid", "JOB#uuid", "PERSON#uuid", etc.

IAM: Lambda execution role needs dynamodb:UpdateItem on the catalog table.

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

    DELETE /sync/catalog/{entityType}/{entityId}

    Returns:
        200 with {"deleted": true, "syncTimestamp": <epoch>}
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

        path_params = event.get("pathParameters") or {}
        entity_type = path_params.get("entityType", "")
        entity_id = path_params.get("entityId", "")

        if not entity_type or entity_type not in VALID_ENTITY_TYPES:
            return _response(400, {
                "error": f"Invalid entityType '{entity_type}'. Must be one of {sorted(VALID_ENTITY_TYPES)}"
            })
        if not entity_id:
            return _response(400, {"error": "Missing entityId path parameter"})

        now = int(time.time())
        table = dynamodb.Table(TABLE_NAME)
        sk = f"{entity_type}#{entity_id}"

        # Soft-delete: set deletedAt and bump updatedAt so sync clients pick it up
        table.update_item(
            Key={"userId": user_id, "sk": sk},
            UpdateExpression="SET deletedAt = :d, updatedAt = :u",
            ExpressionAttributeValues={
                ":d": now,
                ":u": now,
            },
        )

        logger.info("Soft-deleted: userId=%s sk=%s", user_id, sk)

        return _response(200, {
            "deleted": True,
            "syncTimestamp": now,
        })

    except ClientError as e:
        logger.error("DynamoDB ClientError: %s", e, exc_info=True)
        return _response(500, {"error": str(e)})
    except Exception as e:
        logger.error("Unexpected error in catalog delete: %s", e, exc_info=True)
        return _response(500, {"error": "Internal error deleting catalog entity"})


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
