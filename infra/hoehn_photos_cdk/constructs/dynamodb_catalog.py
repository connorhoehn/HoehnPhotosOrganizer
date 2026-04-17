"""
dynamodb_catalog.py — DynamoDB catalog table construct for HoehnPhotos.

Single-table design for full catalog sync (photos, jobs, people, faces, revisions).

Table: HoehnPhotos-Catalog
    Partition key: userId       (STRING) — Cognito sub
    Sort key:      sk           (STRING) — "PHOTO#uuid", "JOB#uuid", "PERSON#uuid",
                                           "FACE#photoId#faceIndex", "REVISION#uuid"

GSI design:
    GSI1: byUpdatedAt
        PK: userId       (STRING)
        SK: updatedAt    (NUMBER, epoch seconds)
        Projection: ALL
        Usage: "Fetch all entities for user X updated since timestamp T"
               This is the primary incremental-sync query path.

    GSI2: byCanonicalName
        PK: canonicalName (STRING) — camera-assigned filename (e.g. "IMG_1234.CR3")
        SK: userId        (STRING)
        Projection: ALL
        Usage: "Find photo record by filename across users" (cross-device dedup)

Stream:
    NEW_AND_OLD_IMAGES — enables future CDC pipelines (search index, analytics).

Point-in-time recovery:
    Enabled. 35-day restore window covers accidental batch deletes during sync.

Billing:
    PAY_PER_REQUEST (on-demand). Appropriate for personal-use app with
    infrequent, bursty write patterns from desktop + mobile sync clients.
"""

from constructs import Construct
from aws_cdk import (
    aws_dynamodb as dynamodb,
    RemovalPolicy,
)


class HoehnPhotosCatalogTable(Construct):
    """
    DynamoDB table storing the full photo catalog for cloud sync.

    Properties:
        table: the underlying dynamodb.Table
        table_name: resolved CloudFormation table name
    """

    def __init__(self, scope: Construct, id: str, **kwargs) -> None:
        super().__init__(scope, id, **kwargs)

        self.table = dynamodb.Table(
            self,
            "CatalogTable",

            # Partition key: Cognito user sub
            partition_key=dynamodb.Attribute(
                name="userId",
                type=dynamodb.AttributeType.STRING,
            ),

            # Sort key: "PHOTO#uuid", "JOB#uuid", "PERSON#uuid", etc.
            sort_key=dynamodb.Attribute(
                name="sk",
                type=dynamodb.AttributeType.STRING,
            ),

            # On-demand billing — no capacity planning for personal use
            billing_mode=dynamodb.BillingMode.PAY_PER_REQUEST,

            # Point-in-time recovery: 35-day restore window
            point_in_time_recovery=True,

            # DynamoDB Streams for future CDC (search index, analytics)
            stream=dynamodb.StreamViewType.NEW_AND_OLD_IMAGES,

            # RETAIN to prevent data loss during stack updates
            removal_policy=RemovalPolicy.RETAIN,
        )

        # GSI1: byUpdatedAt — incremental sync query path
        # "Give me everything for user X that changed since timestamp T"
        self.table.add_global_secondary_index(
            index_name="byUpdatedAt",
            partition_key=dynamodb.Attribute(
                name="userId",
                type=dynamodb.AttributeType.STRING,
            ),
            sort_key=dynamodb.Attribute(
                name="updatedAt",
                type=dynamodb.AttributeType.NUMBER,
            ),
            projection_type=dynamodb.ProjectionType.ALL,
        )

        # GSI2: byCanonicalName — photo lookup by camera-assigned filename
        # "Find photo record for IMG_1234.CR3 across users"
        self.table.add_global_secondary_index(
            index_name="byCanonicalName",
            partition_key=dynamodb.Attribute(
                name="canonicalName",
                type=dynamodb.AttributeType.STRING,
            ),
            sort_key=dynamodb.Attribute(
                name="userId",
                type=dynamodb.AttributeType.STRING,
            ),
            projection_type=dynamodb.ProjectionType.ALL,
        )

    @property
    def table_name(self) -> str:
        """CloudFormation-resolved table name for Lambda env var injection."""
        return self.table.table_name
