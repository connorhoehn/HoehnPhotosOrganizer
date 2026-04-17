"""
presigned_url_handler.py — Lambda that generates presigned PUT/GET URLs for S3.

Endpoint: POST /sync/proxies, POST /sync/curves (via API Gateway)
Called by: S3PresignedURLProvider.swift (Swift client side)

Architecture:
    - Client sends {key, method, contentType} in query parameters.
    - Lambda calls s3_client.generate_presigned_url() with 15-minute expiration.
    - Returns {url, expiresAt} as JSON.
    - Lambda never handles binary data — client PUTs/GETs directly to S3.

Environment variables (injected by CDK stack):
    BUCKET_NAME                  — S3 bucket for all assets (proxies/, curves/, catalog/)
    TABLE_NAME                   — DynamoDB thread table name
    PRESIGNED_URL_EXPIRY_SECONDS — URL lifetime in seconds (default: 900 = 15 minutes)

IAM: Lambda execution role has s3:PutObject, s3:GetObject on bucket/*.
     s3:GeneratePresignedUrl is a client-side SDK call, not an IAM action.

Security:
    - Only allows keys under safe prefixes (proxies/, curves/, catalog/).
    - Rejects keys with path traversal (../).
    - Content-Type is validated against an allowlist.
"""

import json
import os
import boto3
import logging
from datetime import datetime, timezone, timedelta

logger = logging.getLogger()
logger.setLevel(logging.INFO)

BUCKET_NAME = os.environ.get("BUCKET_NAME", "")
EXPIRY_SECONDS = int(os.environ.get("PRESIGNED_URL_EXPIRY_SECONDS", "900"))

# Allowed S3 key prefixes — prevents clients from generating URLs for arbitrary keys.
ALLOWED_PREFIXES = ("proxies/", "curves/", "catalog/exports/", "studio/")

# Allowed Content-Type values for presigned PUT operations.
ALLOWED_CONTENT_TYPES = {
    "image/jpeg",
    "application/octet-stream",
    "application/gzip",
    "text/csv",
    "text/plain",
    "image/png",
}

s3_client = boto3.client("s3")


def handler(event: dict, context) -> dict:
    """
    Entry point for API Gateway proxy integration.

    Expected query string parameters:
        key         — S3 object key (e.g. "proxies/IMG_1234.CR3")
        method      — "PUT" or "GET"
        contentType — MIME type (PUT only; ignored for GET)

    Returns:
        200 with {url: string, expiresAt: ISO8601 string}
        400 with {error: string} for invalid input
        500 with {error: string} for AWS SDK errors
    """
    try:
        params = event.get("queryStringParameters") or {}
        key = params.get("key", "")
        method = params.get("method", "PUT").upper()
        content_type = params.get("contentType", "application/octet-stream")

        # Validate inputs
        validation_error = _validate_request(key, method, content_type)
        if validation_error:
            return _error_response(400, validation_error)

        # Generate presigned URL
        expires_at = datetime.now(tz=timezone.utc) + timedelta(seconds=EXPIRY_SECONDS)

        client_method = "put_object" if method == "PUT" else "get_object"
        params_for_url: dict = {"Bucket": BUCKET_NAME, "Key": key}
        if method == "PUT":
            params_for_url["ContentType"] = content_type

        presigned_url = s3_client.generate_presigned_url(
            ClientMethod=client_method,
            Params=params_for_url,
            ExpiresIn=EXPIRY_SECONDS,
        )

        logger.info("Generated presigned %s URL for key=%s (expires in %ds)", method, key, EXPIRY_SECONDS)

        return {
            "statusCode": 200,
            "headers": {
                "Content-Type": "application/json",
                "Cache-Control": "no-store",
            },
            "body": json.dumps({
                "url": presigned_url,
                "expiresAt": expires_at.isoformat(),
            }),
        }

    except Exception as exc:
        logger.error("Unexpected error generating presigned URL: %s", exc, exc_info=True)
        return _error_response(500, "Internal error generating presigned URL")


def _validate_request(key: str, method: str, content_type: str) -> str | None:
    """Returns an error message string if validation fails, else None."""
    if not key:
        return "Missing required parameter: key"

    if method not in ("PUT", "GET"):
        return f"Invalid method '{method}'. Must be PUT or GET."

    # Guard against path traversal
    if ".." in key or key.startswith("/"):
        return f"Invalid key '{key}': path traversal not allowed"

    # Enforce prefix allowlist
    if not any(key.startswith(prefix) for prefix in ALLOWED_PREFIXES):
        allowed = ", ".join(ALLOWED_PREFIXES)
        return f"Key '{key}' is not under an allowed prefix ({allowed})"

    # Validate content type for PUT
    if method == "PUT" and content_type not in ALLOWED_CONTENT_TYPES:
        return f"Content-Type '{content_type}' is not allowed"

    if not BUCKET_NAME:
        return "BUCKET_NAME environment variable is not set"

    return None


def _error_response(status_code: int, message: str) -> dict:
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"error": message}),
    }
