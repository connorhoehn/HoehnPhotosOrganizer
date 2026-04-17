"""
s3_private_bucket.py — Private S3 bucket construct for HoehnPhotos sync.

Design decisions:
- Versioning enabled: proxies and curve files are immutable per sync operation,
  but versioning lets us recover from accidental deletion or corruption.
- Block all public access: all client access goes through presigned URLs issued
  by Lambda (Wave 2). No direct bucket-policy-level access is granted.
- Bucket policy: explicit DENY for s3:GetObject without presigned URL conditions
  is NOT added here (presigned URL access is already restricted by IAM; adding
  an explicit Deny would block the presigned URL flow itself). Instead, access
  is controlled by granting only the Lambda execution role PutObject/GetObject.
- Lifecycle: Glacier transition after 90 days is documented but commented out.
  Enable once the archive workflow (Phase 8) is scoped and pricing is confirmed.
- Deletion policy: RETAIN in production to prevent accidental data loss.
  In dev/test environments, set removal_policy=RemovalPolicy.DESTROY for cleanup.
"""

from constructs import Construct
from aws_cdk import (
    aws_s3 as s3,
    RemovalPolicy,
    Duration,
)


class HoehnPhotosPrivateBucket(Construct):
    """
    Private S3 bucket for storing HoehnPhotos sync assets.

    Asset prefixes (defined in config.json, enforced at Lambda layer):
        proxies/   — JPEG proxy images (≤ 1600 px, ~2 MB each)
        threads/   — thread entry batch exports (JSON)
        curves/    — curve files (.acv, .csv, .lut, .cube)
        catalog/   — SQLite catalog export snapshots

    Properties:
        bucket: the underlying s3.Bucket
        bucket_name: resolved CloudFormation bucket name
    """

    def __init__(self, scope: Construct, id: str, **kwargs) -> None:
        super().__init__(scope, id, **kwargs)

        self.bucket = s3.Bucket(
            self,
            "PhotoSyncBucket",

            # Versioning: required for point-in-time restore of proxies/curves.
            versioned=True,

            # Block all public access — clients MUST use presigned URLs.
            block_public_access=s3.BlockPublicAccess.BLOCK_ALL,
            public_read_access=False,

            # Enforce HTTPS-only access (reject HTTP requests with 403).
            enforce_ssl=True,

            # Encrypt at rest using AWS-managed keys (SSE-S3).
            # Switch to KMS if customer-managed key rotation is needed later.
            encryption=s3.BucketEncryption.S3_MANAGED,

            # Lifecycle rules — Wave 2 will confirm these before enabling.
            lifecycle_rules=[
                # Uncomment to archive non-current versions after 90 days.
                # (Enable once archive workflow is scoped in Phase 8.)
                # s3.LifecycleRule(
                #     noncurrent_version_transitions=[
                #         s3.NoncurrentVersionTransition(
                #             storage_class=s3.StorageClass.GLACIER,
                #             transition_after=Duration.days(90),
                #         )
                #     ]
                # ),
                # Expire incomplete multipart uploads after 7 days.
                s3.LifecycleRule(
                    abort_incomplete_multipart_upload_after=Duration.days(7),
                )
            ],

            # RETAIN in all environments to prevent accidental photo loss.
            # Change to DESTROY only in isolated test accounts.
            removal_policy=RemovalPolicy.RETAIN,
        )

    @property
    def bucket_name(self) -> str:
        """CloudFormation-resolved bucket name for Lambda env var injection."""
        return self.bucket.bucket_name
