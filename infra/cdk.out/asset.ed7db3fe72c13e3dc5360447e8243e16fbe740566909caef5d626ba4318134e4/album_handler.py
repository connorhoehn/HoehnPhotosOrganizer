"""
album_handler.py — Lambda handler for shared photo album CRUD and public share links.

Routes (all behind Cognito auth except GET /a/{token}):
    POST   /albums                          — create album
    PUT    /albums/{albumId}                — update album metadata
    GET    /albums/{albumId}/photos         — list album photos (paginated)
    POST   /albums/{albumId}/photos         — add photos to album (batch)
    DELETE /albums/{albumId}/photos/{photoId} — remove photo from album
    POST   /albums/{albumId}/links          — create share link
    DELETE /albums/{albumId}/links/{token}  — deactivate share link
    GET    /a/{token}                       — PUBLIC: resolve share link, return album manifest

Environment variables (injected by CDK stack):
    ALBUMS_TABLE_NAME       — DynamoDB Albums table
    SHARE_LINKS_TABLE_NAME  — DynamoDB ShareLinks table
    BUCKET_NAME             — S3 bucket for proxy images (presigned GET URLs)
    PRESIGNED_URL_EXPIRY_SECONDS — URL lifetime (default 900 = 15 minutes)

IAM: Lambda execution role has:
    dynamodb: read/write on Albums + ShareLinks tables (and GSIs)
    s3: GetObject on bucket (for presigned GET URL signing)
"""

import json
import os
import uuid
import secrets
import base64
import time
import boto3
import logging
from datetime import datetime, timezone, timedelta
from boto3.dynamodb.conditions import Key

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ALBUMS_TABLE_NAME = os.environ.get("ALBUMS_TABLE_NAME", "")
SHARE_LINKS_TABLE_NAME = os.environ.get("SHARE_LINKS_TABLE_NAME", "")
BUCKET_NAME = os.environ.get("BUCKET_NAME", "")
EXPIRY_SECONDS = int(os.environ.get("PRESIGNED_URL_EXPIRY_SECONDS", "900"))

dynamodb_resource = boto3.resource("dynamodb")
s3_client = boto3.client("s3")


def handler(event: dict, context) -> dict:
    """
    Entry point for API Gateway proxy integration.

    Routes requests based on httpMethod + resource path.
    """
    try:
        method = event.get("httpMethod", "")
        resource = event.get("resource", "")
        path_params = event.get("pathParameters") or {}

        # Router
        if resource == "/albums" and method == "POST":
            return _create_album(event)

        elif resource == "/albums/{albumId}" and method == "PUT":
            return _update_album(event, path_params["albumId"])

        elif resource == "/albums/{albumId}/photos" and method == "GET":
            return _list_photos(event, path_params["albumId"])

        elif resource == "/albums/{albumId}/photos" and method == "POST":
            return _add_photos(event, path_params["albumId"])

        elif resource == "/albums/{albumId}/photos/{photoId}" and method == "DELETE":
            return _remove_photo(path_params["albumId"], path_params["photoId"])

        elif resource == "/albums/{albumId}/links" and method == "POST":
            return _create_share_link(event, path_params["albumId"])

        elif resource == "/albums/{albumId}/links/{token}" and method == "DELETE":
            return _deactivate_link(path_params["albumId"], path_params["token"])

        elif resource == "/a/{token}" and method == "GET":
            return _resolve_share_link(path_params["token"])

        else:
            return _error_response(404, f"No route for {method} {resource}")

    except json.JSONDecodeError as exc:
        return _error_response(400, f"Invalid JSON body: {exc}")
    except Exception as exc:
        logger.error("Unhandled error: %s", exc, exc_info=True)
        return _error_response(500, "Internal server error")


# ── Route Handlers ──────────────────────────────────────────────────────────


def _create_album(event: dict) -> dict:
    """POST /albums — create a new album with META item."""
    body = _parse_body(event)
    title = body.get("title", "Untitled Album")
    description = body.get("description", "")
    owner_id = _get_owner_id(event)

    album_id = str(uuid.uuid4())
    now = int(time.time())

    table = dynamodb_resource.Table(ALBUMS_TABLE_NAME)
    table.put_item(Item={
        "albumId": album_id,
        "itemType": "META",
        "ownerId": owner_id,
        "title": title,
        "description": description,
        "coverPhotoKey": "",
        "photoCount": 0,
        "createdAt": now,
        "updatedAt": now,
    })

    logger.info("Created album %s for owner %s", album_id, owner_id)
    return _json_response(201, {"albumId": album_id, "title": title})


def _update_album(event: dict, album_id: str) -> dict:
    """PUT /albums/{albumId} — update album metadata (title, description, cover)."""
    body = _parse_body(event)
    now = int(time.time())

    update_expr_parts = ["#updatedAt = :updatedAt"]
    expr_names = {"#updatedAt": "updatedAt"}
    expr_values = {":updatedAt": now}

    for field in ("title", "description", "coverPhotoKey"):
        if field in body:
            safe_name = f"#{field}"
            update_expr_parts.append(f"{safe_name} = :{field}")
            expr_names[safe_name] = field
            expr_values[f":{field}"] = body[field]

    table = dynamodb_resource.Table(ALBUMS_TABLE_NAME)
    table.update_item(
        Key={"albumId": album_id, "itemType": "META"},
        UpdateExpression="SET " + ", ".join(update_expr_parts),
        ExpressionAttributeNames=expr_names,
        ExpressionAttributeValues=expr_values,
    )

    logger.info("Updated album %s", album_id)
    return _json_response(200, {"updated": True, "albumId": album_id})


def _list_photos(event: dict, album_id: str) -> dict:
    """GET /albums/{albumId}/photos — paginated list of photos in album order."""
    query_params = event.get("queryStringParameters") or {}
    limit = min(int(query_params.get("limit", "100")), 500)
    exclusive_start_key = query_params.get("startKey")

    table = dynamodb_resource.Table(ALBUMS_TABLE_NAME)
    query_kwargs = {
        "KeyConditionExpression": Key("albumId").eq(album_id) & Key("itemType").begins_with("PHOTO#"),
        "Limit": limit,
    }
    if exclusive_start_key:
        query_kwargs["ExclusiveStartKey"] = {
            "albumId": album_id,
            "itemType": exclusive_start_key,
        }

    result = table.query(**query_kwargs)
    photos = result.get("Items", [])

    response_body = {"photos": photos}
    last_key = result.get("LastEvaluatedKey")
    if last_key:
        response_body["nextStartKey"] = last_key.get("itemType", "")

    return _json_response(200, response_body)


def _add_photos(event: dict, album_id: str) -> dict:
    """POST /albums/{albumId}/photos — batch-add photos to album."""
    body = _parse_body(event)
    photos = body.get("photos", [])

    if not photos:
        return _error_response(400, "Missing or empty 'photos' array")
    if len(photos) > 25:
        return _error_response(400, "Maximum 25 photos per batch (DynamoDB limit)")

    table = dynamodb_resource.Table(ALBUMS_TABLE_NAME)

    # Get current photo count to continue sequence numbering
    meta_resp = table.get_item(Key={"albumId": album_id, "itemType": "META"})
    meta = meta_resp.get("Item")
    if not meta:
        return _error_response(404, f"Album {album_id} not found")

    current_count = int(meta.get("photoCount", 0))
    now = int(time.time())

    with table.batch_writer() as batch:
        for i, photo in enumerate(photos):
            seq = current_count + i + 1
            photo_id = photo.get("photoId", "")
            if not photo_id:
                continue
            batch.put_item(Item={
                "albumId": album_id,
                "itemType": f"PHOTO#{seq:08d}#{photo_id}",
                "photoId": photo_id,
                "s3Key": photo.get("s3Key", f"proxies/{photo_id}"),
                "caption": photo.get("caption", ""),
                "addedAt": now,
            })

    # Update photo count and updatedAt on META
    new_count = current_count + len(photos)
    table.update_item(
        Key={"albumId": album_id, "itemType": "META"},
        UpdateExpression="SET photoCount = :count, updatedAt = :now",
        ExpressionAttributeValues={":count": new_count, ":now": now},
    )

    logger.info("Added %d photos to album %s (total: %d)", len(photos), album_id, new_count)
    return _json_response(200, {"added": len(photos), "totalCount": new_count})


def _remove_photo(album_id: str, photo_id: str) -> dict:
    """DELETE /albums/{albumId}/photos/{photoId} — remove a photo from album."""
    table = dynamodb_resource.Table(ALBUMS_TABLE_NAME)

    # Find the photo item by querying for PHOTO# items and matching photoId
    result = table.query(
        KeyConditionExpression=Key("albumId").eq(album_id) & Key("itemType").begins_with("PHOTO#"),
    )

    target_key = None
    for item in result.get("Items", []):
        if item.get("photoId") == photo_id:
            target_key = item["itemType"]
            break

    if not target_key:
        return _error_response(404, f"Photo {photo_id} not found in album {album_id}")

    table.delete_item(Key={"albumId": album_id, "itemType": target_key})

    # Decrement photo count
    now = int(time.time())
    table.update_item(
        Key={"albumId": album_id, "itemType": "META"},
        UpdateExpression="SET photoCount = photoCount - :one, updatedAt = :now",
        ExpressionAttributeValues={":one": 1, ":now": now},
    )

    logger.info("Removed photo %s from album %s", photo_id, album_id)
    return _json_response(200, {"removed": True, "photoId": photo_id})


def _create_share_link(event: dict, album_id: str) -> dict:
    """POST /albums/{albumId}/links — create a share link with a random token."""
    body = _parse_body(event)
    expires_in_days = body.get("expiresInDays", 30)

    # Generate a URL-safe random token (22 chars, ~128 bits of entropy)
    token = base64.urlsafe_b64encode(secrets.token_bytes(16)).rstrip(b"=").decode("ascii")
    now = int(time.time())
    expires_at = now + (expires_in_days * 86400) if expires_in_days else 0

    table = dynamodb_resource.Table(SHARE_LINKS_TABLE_NAME)
    table.put_item(Item={
        "token": token,
        "SK": "LINK",
        "albumId": album_id,
        "createdAt": now,
        "expiresAt": expires_at,
        "isActive": True,
        "createdBy": _get_owner_id(event),
    })

    logger.info("Created share link %s for album %s (expires in %d days)", token, album_id, expires_in_days)
    return _json_response(201, {
        "token": token,
        "albumId": album_id,
        "expiresAt": expires_at,
        "shareUrl": f"/a/{token}",
    })


def _deactivate_link(album_id: str, token: str) -> dict:
    """DELETE /albums/{albumId}/links/{token} — deactivate a share link."""
    table = dynamodb_resource.Table(SHARE_LINKS_TABLE_NAME)
    now = int(time.time())

    table.update_item(
        Key={"token": token, "SK": "LINK"},
        UpdateExpression="SET isActive = :inactive, deactivatedAt = :now",
        ConditionExpression="albumId = :albumId",
        ExpressionAttributeValues={":inactive": False, ":now": now, ":albumId": album_id},
    )

    logger.info("Deactivated share link %s for album %s", token, album_id)
    return _json_response(200, {"deactivated": True, "token": token})


def _resolve_share_link(token: str) -> dict:
    """GET /a/{token} — PUBLIC: resolve share link and return album manifest."""
    links_table = dynamodb_resource.Table(SHARE_LINKS_TABLE_NAME)
    link_resp = links_table.get_item(Key={"token": token, "SK": "LINK"})
    link = link_resp.get("Item")

    if not link:
        return _error_response(404, "Share link not found")

    # Check if link is active
    if not link.get("isActive", False):
        return _error_response(410, "This share link has been deactivated")

    # Check expiry
    expires_at = link.get("expiresAt", 0)
    if expires_at and int(time.time()) > expires_at:
        return _error_response(410, "This share link has expired")

    album_id = link["albumId"]
    albums_table = dynamodb_resource.Table(ALBUMS_TABLE_NAME)

    # Fetch album metadata
    meta_resp = albums_table.get_item(Key={"albumId": album_id, "itemType": "META"})
    meta = meta_resp.get("Item")
    if not meta:
        return _error_response(404, "Album not found")

    # Fetch all photos
    photo_result = albums_table.query(
        KeyConditionExpression=Key("albumId").eq(album_id) & Key("itemType").begins_with("PHOTO#"),
    )
    photo_items = photo_result.get("Items", [])

    # Build manifest with presigned GET URLs
    cover_key = meta.get("coverPhotoKey", "")
    cover_url = _presigned_get_url(cover_key) if cover_key else ""

    photos = []
    for item in photo_items:
        s3_key = item.get("s3Key", "")
        photos.append({
            "proxyUrl": _presigned_get_url(s3_key) if s3_key else "",
            "caption": item.get("caption", ""),
            "photoId": item.get("photoId", ""),
        })

    manifest = {
        "title": meta.get("title", ""),
        "description": meta.get("description", ""),
        "coverPhotoUrl": cover_url,
        "photos": photos,
    }

    return _json_response(200, manifest)


# ── Helpers ─────────────────────────────────────────────────────────────────


def _parse_body(event: dict) -> dict:
    """Parse JSON body from API Gateway event."""
    body_str = event.get("body") or "{}"
    return json.loads(body_str)


def _get_owner_id(event: dict) -> str:
    """Extract user ID from Cognito authorizer claims."""
    claims = (event.get("requestContext", {})
              .get("authorizer", {})
              .get("claims", {}))
    return claims.get("sub", "anonymous")


def _presigned_get_url(s3_key: str) -> str:
    """Generate a presigned GET URL for an S3 object (15-min expiry)."""
    if not s3_key or not BUCKET_NAME:
        return ""
    return s3_client.generate_presigned_url(
        ClientMethod="get_object",
        Params={"Bucket": BUCKET_NAME, "Key": s3_key},
        ExpiresIn=EXPIRY_SECONDS,
    )


def _json_response(status_code: int, body: dict) -> dict:
    """Build an API Gateway proxy-integration JSON response."""
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Cache-Control": "no-store",
        },
        "body": json.dumps(body, default=str),
    }


def _error_response(status_code: int, message: str) -> dict:
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"error": message}),
    }
