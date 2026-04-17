"""
dynamodb_threads.py — DynamoDB thread table construct for HoehnPhotos.

Table design (mirrors DynamoDB GSI pattern from lifeeventscloud):
    Partition key: threadRootId  (string) — photo canonical_id e.g. "IMG_1234.CR3"
    Sort key:      sortKey       (string) — format: "<timestamp>#<entryId>"
                                            enables chronological replay within a thread

    Example items:
        PK: IMG_1234.CR3  SK: 1710595200#B8F2A3D1-...   type: note
        PK: IMG_1234.CR3  SK: 1710596000#C9E3B4F2-...   type: ai_turn
        PK: IMG_1234.CR3  SK: 1710597000#D0F4C5A3-...   type: print_attempt

GSI design:
    Index name: byThreadRoot
    PK: threadRootId   (same as table PK)
    SK: timestamp      (numeric projection for range queries)
    Projection: ALL    (all attributes needed for full thread restore)

    Usage: "Fetch all entries for photo X since timestamp T, ascending"
    This is the primary restore/replay query path.

TTL:
    TTL attribute: ttl (optional, epoch seconds)
    Not enforced by default — document for future pruning of abandoned threads.
    Enable per-item TTL in Wave 4 when thread pruning policy is defined.

Point-in-time recovery:
    Enabled. Allows restoring the table to any second within the last 35 days.
    Covers accidental batch deletes during sync or restore operations.

Billing:
    PAY_PER_REQUEST (on-demand). Appropriate for a personal-use app with
    infrequent, bursty write patterns. Switch to PROVISIONED if costs spike.
"""

from constructs import Construct
from aws_cdk import (
    aws_dynamodb as dynamodb,
    RemovalPolicy,
)


class HoehnPhotosThreadTable(Construct):
    """
    DynamoDB table storing per-photo thread entries for cloud sync.

    Properties:
        table: the underlying dynamodb.Table
        table_name: resolved CloudFormation table name
    """

    def __init__(self, scope: Construct, id: str, **kwargs) -> None:
        super().__init__(scope, id, **kwargs)

        self.table = dynamodb.Table(
            self,
            "ThreadEntryTable",

            # Partition key: photo canonical_id (camera-assigned filename)
            partition_key=dynamodb.Attribute(
                name="threadRootId",
                type=dynamodb.AttributeType.STRING,
            ),

            # Sort key: "<unix_timestamp>#<entryId>" for chronological ordering
            sort_key=dynamodb.Attribute(
                name="sortKey",
                type=dynamodb.AttributeType.STRING,
            ),

            # On-demand billing — no capacity planning for personal use
            billing_mode=dynamodb.BillingMode.PAY_PER_REQUEST,

            # Point-in-time recovery: 35-day restore window
            point_in_time_recovery=True,

            # TTL attribute (not enforced until Wave 4 pruning policy is defined)
            time_to_live_attribute="ttl",

            # RETAIN to prevent data loss during stack updates
            removal_policy=RemovalPolicy.RETAIN,
        )

        # GSI: byThreadRoot — enables "all entries for photo X since timestamp T"
        # This is the primary restore/replay query path used in Wave 4.
        self.table.add_global_secondary_index(
            index_name="byThreadRoot",
            partition_key=dynamodb.Attribute(
                name="threadRootId",
                type=dynamodb.AttributeType.STRING,
            ),
            sort_key=dynamodb.Attribute(
                name="timestamp",
                type=dynamodb.AttributeType.NUMBER,
            ),
            projection_type=dynamodb.ProjectionType.ALL,
        )

    @property
    def table_name(self) -> str:
        """CloudFormation-resolved table name for Lambda env var injection."""
        return self.table.table_name
