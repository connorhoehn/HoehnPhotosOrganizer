"""
thread_sync_handler.py — Lambda that writes thread entries to DynamoDB.

Endpoint: POST /sync/threads (via API Gateway)
Called by: ThreadSyncClient.swift (uploadThreadEntries)

Architecture:
    - Client sends {"entries": [...]} JSON body with up to 25 entries per request.
    - Lambda chunks entries into DynamoDB BatchWriteItem calls (25-item hard limit).
    - Returns {"syncTimestamp": <unix_epoch>, "writtenCount": N} on success.
    - Throttling (503) is retryable — caller should back off and retry.

DynamoDB table: HoehnPhotos-ThreadEntries (controlled by THREAD_TABLE_NAME env var)
    PK: threadRootId   — photo canonical_id (e.g. "IMG_1234.CR3")
    SK: sortKey        — "<timestamp>#<entryId>" enables chronological GSI replay

IAM: Lambda execution role needs dynamodb:BatchWriteItem on the table.

Environment variables (injected by CDK stack):
    THREAD_TABLE_NAME  — DynamoDB table name (default: "HoehnPhotos-ThreadEntries")
"""

import json
import os
import time
import boto3
from botocore.exceptions import ClientError

TABLE_NAME = os.environ.get("THREAD_TABLE_NAME", "HoehnPhotos-ThreadEntries")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)


def handler(event, context):
    """Receives batch of thread entries, writes to DynamoDB.

    POST /sync/threads
    Body: {"entries": [{"entryId": "...", "threadRootId": "...", "timestamp": 123, ...}]}

    Returns:
        200 with {"syncTimestamp": <epoch>, "writtenCount": N}
        400 with {"error": "No entries provided"} for empty body
        500/503 with {"error": ..., "retryable": bool} for AWS errors
    """
    try:
        body = json.loads(event.get("body") or "{}")
        entries = body.get("entries", [])

        if not entries:
            return _response(400, {"error": "No entries provided"})

        written = 0
        # DynamoDB BatchWriteItem max 25 items per call
        for i in range(0, len(entries), 25):
            batch = entries[i:i + 25]
            with table.batch_writer() as writer:
                for entry in batch:
                    sort_key = f"{entry['timestamp']}#{entry['entryId']}"
                    item = {
                        "threadRootId": entry["threadRootId"],
                        "sortKey": sort_key,
                        "entryId": entry["entryId"],
                        "kind": entry.get("kind", "text_note"),
                        "content": entry.get("content", ""),
                        "timestamp": entry["timestamp"],
                        "metadata": json.dumps(entry.get("metadata") or {}),
                    }
                    writer.put_item(Item=item)
                    written += 1

        sync_timestamp = int(time.time())
        return _response(200, {
            "syncTimestamp": sync_timestamp,
            "writtenCount": written,
        })

    except ClientError as e:
        error_code = e.response["Error"]["Code"]
        if error_code in ("ProvisionedThroughputExceededException", "ThrottlingException"):
            return _response(503, {"error": "DynamoDB throttled", "retryable": True})
        return _response(500, {"error": str(e), "retryable": False})
    except Exception as e:
        return _response(500, {"error": str(e), "retryable": False})


def _response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }
