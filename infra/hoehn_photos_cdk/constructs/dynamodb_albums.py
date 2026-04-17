"""
dynamodb_albums.py — DynamoDB tables for shared photo albums.

Table 1: HoehnPhotos-Albums (single-table design)
    Partition key: albumId   (STRING) — UUID identifying the album
    Sort key:      itemType  (STRING) — "META" for album metadata,
                                        "PHOTO#00000042#<photoId>" for ordered photos

    The PHOTO sort key encodes a zero-padded sequence number so albums maintain
    explicit ordering. Example items:
        PK: abc-123  SK: META                          → album title, description, cover
        PK: abc-123  SK: PHOTO#00000001#IMG_1234.CR3   → first photo in album
        PK: abc-123  SK: PHOTO#00000002#IMG_5678.CR3   → second photo in album

    GSI: byOwner
        PK: ownerId    (STRING) — userId from Cognito
        SK: updatedAt  (NUMBER) — epoch seconds
        Projection: ALL
        Usage: "List all albums for the current user, newest first"

Table 2: HoehnPhotos-ShareLinks
    Partition key: token  (STRING) — URL-safe random token (e.g. base64url, 22 chars)
    Sort key:      SK     (STRING) — constant "LINK"

    GSI: byAlbum
        PK: albumId    (STRING) — album UUID
        SK: createdAt  (NUMBER) — epoch seconds
        Projection: ALL
        Usage: "List all share links for an album"

Billing: PAY_PER_REQUEST for both tables (personal-use, bursty traffic).
PITR: Enabled on Albums table (holds primary data). Not on ShareLinks (ephemeral).
Removal: RETAIN on both tables to prevent accidental data loss.
"""

from constructs import Construct
from aws_cdk import (
    aws_dynamodb as dynamodb,
    RemovalPolicy,
)


class HoehnPhotosAlbumTables(Construct):
    """
    DynamoDB tables for shared photo albums and share links.

    Properties:
        albums_table:      the HoehnPhotos-Albums table
        share_links_table: the HoehnPhotos-ShareLinks table
    """

    def __init__(self, scope: Construct, id: str, **kwargs) -> None:
        super().__init__(scope, id, **kwargs)

        # ── Albums Table ────────────────────────────────────────────────────
        self.albums_table = dynamodb.Table(
            self,
            "AlbumsTable",

            # Partition key: album UUID
            partition_key=dynamodb.Attribute(
                name="albumId",
                type=dynamodb.AttributeType.STRING,
            ),

            # Sort key: "META" or "PHOTO#<seq>#<photoId>"
            sort_key=dynamodb.Attribute(
                name="itemType",
                type=dynamodb.AttributeType.STRING,
            ),

            billing_mode=dynamodb.BillingMode.PAY_PER_REQUEST,
            point_in_time_recovery=True,
            removal_policy=RemovalPolicy.RETAIN,
        )

        # GSI: byOwner — list all albums for a user, ordered by updatedAt desc
        self.albums_table.add_global_secondary_index(
            index_name="byOwner",
            partition_key=dynamodb.Attribute(
                name="ownerId",
                type=dynamodb.AttributeType.STRING,
            ),
            sort_key=dynamodb.Attribute(
                name="updatedAt",
                type=dynamodb.AttributeType.NUMBER,
            ),
            projection_type=dynamodb.ProjectionType.ALL,
        )

        # ── Share Links Table ───────────────────────────────────────────────
        self.share_links_table = dynamodb.Table(
            self,
            "ShareLinksTable",

            # Partition key: URL-safe random token
            partition_key=dynamodb.Attribute(
                name="token",
                type=dynamodb.AttributeType.STRING,
            ),

            # Sort key: constant "LINK"
            sort_key=dynamodb.Attribute(
                name="SK",
                type=dynamodb.AttributeType.STRING,
            ),

            billing_mode=dynamodb.BillingMode.PAY_PER_REQUEST,
            removal_policy=RemovalPolicy.RETAIN,
        )

        # GSI: byAlbum — list all share links for a given album
        self.share_links_table.add_global_secondary_index(
            index_name="byAlbum",
            partition_key=dynamodb.Attribute(
                name="albumId",
                type=dynamodb.AttributeType.STRING,
            ),
            sort_key=dynamodb.Attribute(
                name="createdAt",
                type=dynamodb.AttributeType.NUMBER,
            ),
            projection_type=dynamodb.ProjectionType.ALL,
        )
