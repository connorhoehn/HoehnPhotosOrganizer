"""
thread_query_handler.py — Lambda that queries thread entries from DynamoDB by photo.

Endpoint: GET /sync/threads/{photoId} (via API Gateway)
Called by: ThreadSyncClient.swift (queryThreadHistory)

Architecture:
    - Client sends photoId as a path parameter.
    - Lambda queries DynamoDB with threadRootId as partition key, ScanIndexForward=true
      to return entries in chronological order (ascending timestamp).
    - Returns {"entries": [...]} with all entries for the photo.

DynamoDB table: HoehnPhotos-ThreadEntries (controlled by THREAD_TABLE_NAME env var)
    PK: threadRootId   — photo canonical_id (e.g. "IMG_1234.CR3")
    SK: sortKey        — "<timestamp>#<entryId>" enables chronological ordering

IAM: Lambda execution role needs dynamodb:Query on the table.

Environment variables (injected by CDK stack):
    THREAD_TABLE_NAME  — DynamoDB table name (default: "HoehnPhotos-ThreadEntries")
"""

import json
import os
import boto3
from boto3.dynamodb.conditions import Key

TABLE_NAME = os.environ.get("THREAD_TABLE_NAME", "HoehnPhotos-ThreadEntries")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)


def handler(event, context):
    """Query thread entries for a photo in chronological order.

    GET /sync/threads/{photoId}

    Returns:
        200 with {"entries": [...]}
        400 with {"error": "Missing photoId path parameter"}
        500 with {"error": ...}
    """
    try:
        path_params = event.get("pathParameters") or {}
        photo_id = path_params.get("threadRootId") or path_params.get("photoId")

        if not photo_id:
            return _response(400, {"error": "Missing threadRootId path parameter"})

        # Query with ScanIndexForward=True for chronological (ascending) order
        response = table.query(
            KeyConditionExpression=Key("threadRootId").eq(photo_id),
            ScanIndexForward=True,
        )

        entries = []
        for item in response.get("Items", []):
            entries.append({
                "entryId": item.get("entryId"),
                "threadRootId": item.get("threadRootId"),
                "kind": item.get("kind"),
                "content": item.get("content"),
                "timestamp": int(item.get("timestamp", 0)),
                "metadata": json.loads(item.get("metadata") or "{}"),
            })

        return _response(200, {"entries": entries})

    except Exception as e:
        return _response(500, {"error": str(e)})


def _response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }
