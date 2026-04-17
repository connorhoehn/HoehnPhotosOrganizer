"""
sync_stack.py — HoehnPhotosSync CDK stack.

This stack is the entry point for all cloud sync infrastructure.
It wires together:
    1. S3 private bucket        — proxy images, curve files, thread exports
    2. DynamoDB thread table    — per-photo editorial thread entries
    3. Lambda: presigned URL generator  — Wave 2 implementation (real handler)
    4. Lambda: catalog export recorder  — Wave 2 implementation (real handler)
    5. Lambda: thread sync writer      — batch-writes thread entries to DynamoDB
    6. Lambda: thread query reader     — queries thread entries by photo
    7. Lambda: sync status checker     — per-photo sync status (S3 + DynamoDB)
    8. Lambda: restore manifest        — lists all synced assets for restore flow
    9. API Gateway                     — REST API fronting Lambda handlers
   10. Cognito User Pool              — invite-only authentication
   11. DynamoDB album tables          — shared photo albums + share links
   12. Lambda: album handler          — album CRUD + public share link resolution

Wave implementation plan:
    Wave 1 (04-01): Stack scaffold, bucket, table, placeholders
    Wave 2 (04-02): Lambda functions: presigned URL, catalog export recorder
    Wave 3 (04-03): Swift SyncClient actor using generated API client
    Wave 4 (04-04): Restore flow, batch replay, conflict resolution
    Wave 5 (04-08): Cognito auth, thread sync/query, sync status, restore manifest, studio prefix
    Wave 6 (04-08): Shared album infrastructure (albums, share links, album handler)

Outputs:
    PhotoSyncBucketName    — S3 bucket name for Swift app plist / Lambda env
    ThreadEntryTableName   — DynamoDB table name for Lambda env
    AlbumsTableName        — DynamoDB Albums table name
    ShareLinksTableName    — DynamoDB ShareLinks table name
    SyncApiEndpoint        — API Gateway invoke URL
    UserPoolId             — Cognito User Pool ID for Swift app config
    UserPoolClientId       — Cognito User Pool Client ID for Swift app config

IAM design:
    Lambda execution role gets narrowly-scoped permissions:
        s3:GetObject, s3:PutObject on bucket/* (for presigned URL signing)
        dynamodb:PutItem, GetItem, Query, BatchWriteItem on table
    Album Lambda gets:
        dynamodb: read/write on Albums + ShareLinks tables
        s3:GetObject on bucket (for presigned GET URLs in public album view)
    No other resources have direct access to the bucket or table.
    All client access via presigned URLs (never raw S3 credentials).
"""

import os
from constructs import Construct
from aws_cdk import (
    Stack,
    CfnOutput,
    aws_lambda as lambda_,
    aws_apigateway as apigateway,
    Duration,
)
from hoehn_photos_cdk.constructs.s3_private_bucket import HoehnPhotosPrivateBucket
from hoehn_photos_cdk.constructs.dynamodb_threads import HoehnPhotosThreadTable
from hoehn_photos_cdk.constructs.dynamodb_catalog import HoehnPhotosCatalogTable
from hoehn_photos_cdk.constructs.dynamodb_albums import HoehnPhotosAlbumTables
from hoehn_photos_cdk.constructs.cognito_auth import HoehnPhotosCognitoAuth

# Path to the lambdas/ directory, relative to this file.
_LAMBDAS_DIR = os.path.join(os.path.dirname(__file__), "..", "lambdas")


class SyncStack(Stack):
    """
    HoehnPhotosSync stack.

    Instantiated by app.py with stack_id = 'HoehnPhotosSync'.
    All resource logical IDs are stable — do not rename without a migration plan.
    """

    def __init__(self, scope: Construct, construct_id: str, **kwargs) -> None:
        super().__init__(scope, construct_id, **kwargs)

        # ── S3 Private Bucket ──────────────────────────────────────────────────
        # Stores proxies/, curves/, threads/, catalog/ prefixes.
        # All client access via presigned URLs issued by Lambda.
        self._bucket_construct = HoehnPhotosPrivateBucket(self, "PhotoStorage")
        bucket = self._bucket_construct.bucket

        # ── DynamoDB Thread Table ─────────────────────────────────────────────
        # Per-photo editorial thread entries. GSI: byThreadRoot.
        self._table_construct = HoehnPhotosThreadTable(self, "ThreadStorage")
        table = self._table_construct.table

        # ── Cognito Authentication ──────────────────────────────────────────
        # Invite-only user pool for family/personal access control.
        self._auth_construct = HoehnPhotosCognitoAuth(self, "Auth")

        # ── DynamoDB Catalog Table ──────────────────────────────────────────
        # Full catalog sync: photos, jobs, people, faces, revisions.
        # Single-table design with GSI1 (byUpdatedAt) and GSI2 (byCanonicalName).
        self._catalog_construct = HoehnPhotosCatalogTable(self, "CatalogStorage")
        catalog_table = self._catalog_construct.table

        # ── DynamoDB Album Tables ─────────────────────────────────────────────
        # Shared photo albums (single-table: META + PHOTO# items) and share links.
        self._album_construct = HoehnPhotosAlbumTables(self, "AlbumStorage")
        albums_table = self._album_construct.albums_table
        share_links_table = self._album_construct.share_links_table

        # Shared Lambda environment variables
        lambda_env = {
            "BUCKET_NAME": bucket.bucket_name,
            "TABLE_NAME": table.table_name,
            "PRESIGNED_URL_EXPIRY_SECONDS": "900",
        }

        # Catalog Lambda environment variables (separate table)
        catalog_lambda_env = {
            "CATALOG_TABLE_NAME": catalog_table.table_name,
        }

        # Album Lambda environment variables
        album_lambda_env = {
            "ALBUMS_TABLE_NAME": albums_table.table_name,
            "SHARE_LINKS_TABLE_NAME": share_links_table.table_name,
            "BUCKET_NAME": bucket.bucket_name,
            "PRESIGNED_URL_EXPIRY_SECONDS": "900",
        }

        # ── Lambda: Presigned URL Generator ───────────────────────────────────
        # Generates presigned PUT/GET URLs for proxies/, curves/, catalog/ keys.
        # Called by S3PresignedURLProvider.swift before each S3 transfer.
        presigned_url_fn = lambda_.Function(
            self,
            "PresignedUrlFunction",
            runtime=lambda_.Runtime.PYTHON_3_12,
            handler="presigned_url_handler.handler",
            code=lambda_.Code.from_asset(_LAMBDAS_DIR),
            description=(
                "Generates presigned S3 PUT/GET URLs for proxy images, curve files, "
                "and catalog exports. Called by S3PresignedURLProvider.swift. "
                "See infra/sync-api.openapi.yaml /sync/proxies and /sync/curves endpoints."
            ),
            timeout=Duration.seconds(30),
            memory_size=256,
            environment=lambda_env,
        )

        # Grant Lambda the minimum required S3 permissions.
        bucket.grant_read_write(presigned_url_fn)

        # ── Lambda: Catalog Export Recorder ──────────────────────────────────
        # Registers catalog export metadata in DynamoDB after Swift client uploads .sql.gz.
        # Restore manifest queries this table to find the latest export.
        catalog_export_fn = lambda_.Function(
            self,
            "CatalogExportFunction",
            runtime=lambda_.Runtime.PYTHON_3_12,
            handler="catalog_export_handler.handler",
            code=lambda_.Code.from_asset(_LAMBDAS_DIR),
            description=(
                "Records catalog export metadata (s3Key, checksum, timestamp) in DynamoDB "
                "after the Swift client uploads a .sql.gz snapshot via presigned URL. "
                "See infra/sync-api.openapi.yaml /sync/catalog endpoint."
            ),
            timeout=Duration.seconds(30),
            memory_size=256,
            environment=lambda_env,
        )

        # Grant catalog export Lambda DynamoDB write access.
        table.grant_read_write_data(catalog_export_fn)
        # Grant table read to presigned URL function too (for sync status reads)
        table.grant_read_write_data(presigned_url_fn)

        # ── Lambda: Thread Sync Writer ─────────────────────────────────────
        # Batch-writes thread entries to DynamoDB.
        # Called by ThreadSyncClient.swift (uploadThreadEntries).
        thread_sync_fn = lambda_.Function(
            self,
            "ThreadSyncFunction",
            runtime=lambda_.Runtime.PYTHON_3_12,
            handler="thread_sync_handler.handler",
            code=lambda_.Code.from_asset(_LAMBDAS_DIR),
            description=(
                "Batch-writes thread entries (notes, AI turns, print attempts) to DynamoDB. "
                "Called by ThreadSyncClient.swift. "
                "See infra/sync-api.openapi.yaml POST /sync/threads endpoint."
            ),
            timeout=Duration.seconds(30),
            memory_size=256,
            environment={
                "THREAD_TABLE_NAME": table.table_name,
            },
        )

        # Grant thread sync Lambda DynamoDB write access.
        table.grant_read_write_data(thread_sync_fn)

        # ── Lambda: Thread Query Reader ────────────────────────────────────
        # Queries thread entries by photo canonical_id.
        # Called by ThreadSyncClient.swift (queryThreadHistory).
        thread_query_fn = lambda_.Function(
            self,
            "ThreadQueryFunction",
            runtime=lambda_.Runtime.PYTHON_3_12,
            handler="thread_query_handler.handler",
            code=lambda_.Code.from_asset(_LAMBDAS_DIR),
            description=(
                "Queries thread entries for a photo in chronological order from DynamoDB. "
                "Called by ThreadSyncClient.swift. "
                "See infra/sync-api.openapi.yaml GET /sync/threads/{threadRootId} endpoint."
            ),
            timeout=Duration.seconds(30),
            memory_size=256,
            environment={
                "THREAD_TABLE_NAME": table.table_name,
            },
        )

        # Grant thread query Lambda DynamoDB read access.
        table.grant_read_data(thread_query_fn)

        # ── Lambda: Sync Status Checker ────────────────────────────────────
        # Returns per-photo sync status (proxy in S3 + thread count in DynamoDB).
        # Called by Swift SyncClient for LibraryView badge icons.
        sync_status_fn = lambda_.Function(
            self,
            "SyncStatusFunction",
            runtime=lambda_.Runtime.PYTHON_3_12,
            handler="sync_status_handler.handler",
            code=lambda_.Code.from_asset(_LAMBDAS_DIR),
            description=(
                "Checks per-photo sync status: proxy existence in S3, thread count in DynamoDB. "
                "See infra/sync-api.openapi.yaml GET /sync/status/{canonicalId} endpoint."
            ),
            timeout=Duration.seconds(30),
            memory_size=256,
            environment=lambda_env,
        )

        # Grant sync status Lambda S3 read (head_object) and DynamoDB read (query).
        bucket.grant_read(sync_status_fn)
        table.grant_read_data(sync_status_fn)

        # ── Lambda: Restore Manifest ───────────────────────────────────────
        # Lists all synced assets (proxies, curves, catalog exports) for restore flow.
        # Called by Swift SyncClient at the start of a restore operation.
        restore_manifest_fn = lambda_.Function(
            self,
            "RestoreManifestFunction",
            runtime=lambda_.Runtime.PYTHON_3_12,
            handler="restore_manifest_handler.handler",
            code=lambda_.Code.from_asset(_LAMBDAS_DIR),
            description=(
                "Lists all synced assets in S3 (proxies/, curves/) and catalog exports in DynamoDB. "
                "Returns a paginated RestoreManifest. "
                "See infra/sync-api.openapi.yaml GET /restore/manifest endpoint."
            ),
            timeout=Duration.seconds(60),
            memory_size=512,
            environment=lambda_env,
        )

        # Grant restore manifest Lambda S3 list + DynamoDB read.
        bucket.grant_read(restore_manifest_fn)
        table.grant_read_data(restore_manifest_fn)

        # ── Lambda: Catalog Batch Sync ─────────────────────────────────────
        # Batch upserts photos/jobs/people/faces/revisions to DynamoDB catalog table.
        # Called by CatalogSyncClient.swift (pushCatalogBatch).
        catalog_sync_fn = lambda_.Function(
            self,
            "CatalogSyncFunction",
            runtime=lambda_.Runtime.PYTHON_3_12,
            handler="catalog_sync_handler.handler",
            code=lambda_.Code.from_asset(_LAMBDAS_DIR),
            description=(
                "Batch-upserts catalog entities (photos, jobs, people, faces, revisions) "
                "to DynamoDB. Called by CatalogSyncClient.swift."
            ),
            timeout=Duration.seconds(30),
            memory_size=256,
            environment=catalog_lambda_env,
        )

        # Grant catalog sync Lambda read/write on the catalog table.
        catalog_table.grant_read_write_data(catalog_sync_fn)

        # ── Lambda: Catalog Query ──────────────────────────────────────────
        # Incremental pull of catalog changes since a given timestamp.
        # Called by CatalogSyncClient.swift (pullCatalogChanges).
        catalog_query_fn = lambda_.Function(
            self,
            "CatalogQueryFunction",
            runtime=lambda_.Runtime.PYTHON_3_12,
            handler="catalog_query_handler.handler",
            code=lambda_.Code.from_asset(_LAMBDAS_DIR),
            description=(
                "Queries catalog entities updated since a given timestamp for incremental sync. "
                "Called by CatalogSyncClient.swift."
            ),
            timeout=Duration.seconds(30),
            memory_size=256,
            environment=catalog_lambda_env,
        )

        # Grant catalog query Lambda read access on the catalog table.
        catalog_table.grant_read_data(catalog_query_fn)

        # ── Lambda: Catalog Delete ─────────────────────────────────────────
        # Soft-deletes catalog entities by setting deletedAt attribute.
        # Called by CatalogSyncClient.swift (deleteCatalogEntity).
        catalog_delete_fn = lambda_.Function(
            self,
            "CatalogDeleteFunction",
            runtime=lambda_.Runtime.PYTHON_3_12,
            handler="catalog_delete_handler.handler",
            code=lambda_.Code.from_asset(_LAMBDAS_DIR),
            description=(
                "Soft-deletes catalog entities by setting deletedAt attribute. "
                "Called by CatalogSyncClient.swift."
            ),
            timeout=Duration.seconds(30),
            memory_size=256,
            environment=catalog_lambda_env,
        )

        # Grant catalog delete Lambda read/write on the catalog table.
        catalog_table.grant_read_write_data(catalog_delete_fn)

        # ── Lambda: Album Handler ──────────────────────────────────────────
        # Handles album CRUD, photo management, share link creation/resolution.
        # Public endpoint GET /a/{token} resolves share links without auth.
        album_fn = lambda_.Function(
            self,
            "AlbumFunction",
            runtime=lambda_.Runtime.PYTHON_3_12,
            handler="album_handler.handler",
            code=lambda_.Code.from_asset(_LAMBDAS_DIR),
            description=(
                "Handles shared photo album CRUD, photo management, and public share link "
                "resolution. GET /a/{token} is public; all other routes require Cognito auth."
            ),
            timeout=Duration.seconds(30),
            memory_size=256,
            environment=album_lambda_env,
        )

        # Grant album Lambda read/write on both album tables.
        albums_table.grant_read_write_data(album_fn)
        share_links_table.grant_read_write_data(album_fn)
        # Grant album Lambda S3 read for presigned GET URLs in public album view.
        bucket.grant_read(album_fn)

        # ── API Gateway ───────────────────────────────────────────────────────
        api = apigateway.RestApi(
            self,
            "SyncApi",
            rest_api_name="HoehnPhotosSyncApi",
            description=(
                "REST API for HoehnPhotosOrganizer cloud sync. "
                "Endpoints: /sync/presign, /sync/catalog, /sync/threads, "
                "/restore/manifest, /albums, /a/{token}."
            ),
            deploy_options=apigateway.StageOptions(
                stage_name="v1",
                description="Wave 6 — shared album infrastructure",
            ),
        )

        # ── Cognito Authorizer ────────────────────────────────────────────
        # All endpoints except /health and GET /a/{token} require a valid
        # Cognito JWT in the Authorization header.
        cognito_authorizer = apigateway.CognitoUserPoolsAuthorizer(
            self,
            "CognitoAuthorizer",
            cognito_user_pools=[self._auth_construct.user_pool],
            authorizer_name="HoehnPhotosCognitoAuthorizer",
        )

        album_integration = apigateway.LambdaIntegration(album_fn)

        # /health — mock health check (always available without auth)
        health_resource = api.root.add_resource("health")
        health_resource.add_method(
            "GET",
            apigateway.MockIntegration(
                integration_responses=[
                    apigateway.IntegrationResponse(
                        status_code="200",
                        response_templates={
                            "application/json": '{"status":"ok","wave":"6"}'
                        },
                    )
                ],
                passthrough_behavior=apigateway.PassthroughBehavior.NEVER,
                request_templates={"application/json": '{"statusCode": 200}'},
            ),
            method_responses=[
                apigateway.MethodResponse(status_code="200")
            ],
        )

        # /sync/presign — presigned URL generation
        sync_resource = api.root.add_resource("sync")
        presign_resource = sync_resource.add_resource("presign")
        presign_resource.add_method(
            "POST",
            apigateway.LambdaIntegration(presigned_url_fn),
            authorizer=cognito_authorizer,
            authorization_type=apigateway.AuthorizationType.COGNITO,
        )

        # /sync/catalog — catalog export metadata registration (POST)
        catalog_resource = sync_resource.add_resource("catalog")
        catalog_resource.add_method(
            "POST",
            apigateway.LambdaIntegration(catalog_export_fn),
            authorizer=cognito_authorizer,
            authorization_type=apigateway.AuthorizationType.COGNITO,
        )

        # /sync/catalog — incremental pull (GET)
        catalog_resource.add_method(
            "GET",
            apigateway.LambdaIntegration(catalog_query_fn),
            authorizer=cognito_authorizer,
            authorization_type=apigateway.AuthorizationType.COGNITO,
        )

        # /sync/catalog/{entityType}/{entityId} — soft-delete (DELETE)
        catalog_entity_type_resource = catalog_resource.add_resource("{entityType}")
        catalog_entity_resource = catalog_entity_type_resource.add_resource("{entityId}")
        catalog_entity_resource.add_method(
            "DELETE",
            apigateway.LambdaIntegration(catalog_delete_fn),
            authorizer=cognito_authorizer,
            authorization_type=apigateway.AuthorizationType.COGNITO,
        )

        # /sync/catalog-batch — batch upsert (POST)
        catalog_batch_resource = sync_resource.add_resource("catalog-batch")
        catalog_batch_resource.add_method(
            "POST",
            apigateway.LambdaIntegration(catalog_sync_fn),
            authorizer=cognito_authorizer,
            authorization_type=apigateway.AuthorizationType.COGNITO,
        )

        # /sync/threads — thread entry batch upload (POST)
        threads_resource = sync_resource.add_resource("threads")
        threads_resource.add_method(
            "POST",
            apigateway.LambdaIntegration(thread_sync_fn),
            authorizer=cognito_authorizer,
            authorization_type=apigateway.AuthorizationType.COGNITO,
        )

        # /sync/threads/{threadRootId} — query thread entries for a photo (GET)
        thread_by_id_resource = threads_resource.add_resource("{threadRootId}")
        thread_by_id_resource.add_method(
            "GET",
            apigateway.LambdaIntegration(thread_query_fn),
            authorizer=cognito_authorizer,
            authorization_type=apigateway.AuthorizationType.COGNITO,
        )

        # /sync/status/{canonicalId} — per-photo sync status (GET)
        status_resource = sync_resource.add_resource("status")
        status_by_id_resource = status_resource.add_resource("{canonicalId}")
        status_by_id_resource.add_method(
            "GET",
            apigateway.LambdaIntegration(sync_status_fn),
            authorizer=cognito_authorizer,
            authorization_type=apigateway.AuthorizationType.COGNITO,
        )

        # /restore/manifest — restore manifest listing (GET)
        restore_resource = api.root.add_resource("restore")
        manifest_resource = restore_resource.add_resource("manifest")
        manifest_resource.add_method(
            "GET",
            apigateway.LambdaIntegration(restore_manifest_fn),
            authorizer=cognito_authorizer,
            authorization_type=apigateway.AuthorizationType.COGNITO,
        )

        # ── Album API Routes ──────────────────────────────────────────────────

        # POST /albums — create album (auth required)
        albums_resource = api.root.add_resource("albums")
        albums_resource.add_method(
            "POST",
            album_integration,
            authorizer=cognito_authorizer,
            authorization_type=apigateway.AuthorizationType.COGNITO,
        )

        # PUT /albums/{albumId} — update album metadata (auth required)
        album_by_id_resource = albums_resource.add_resource("{albumId}")
        album_by_id_resource.add_method(
            "PUT",
            album_integration,
            authorizer=cognito_authorizer,
            authorization_type=apigateway.AuthorizationType.COGNITO,
        )

        # GET /albums/{albumId}/photos — list photos (auth required)
        # POST /albums/{albumId}/photos — add photos (auth required)
        album_photos_resource = album_by_id_resource.add_resource("photos")
        album_photos_resource.add_method(
            "GET",
            album_integration,
            authorizer=cognito_authorizer,
            authorization_type=apigateway.AuthorizationType.COGNITO,
        )
        album_photos_resource.add_method(
            "POST",
            album_integration,
            authorizer=cognito_authorizer,
            authorization_type=apigateway.AuthorizationType.COGNITO,
        )

        # DELETE /albums/{albumId}/photos/{photoId} — remove photo (auth required)
        album_photo_by_id_resource = album_photos_resource.add_resource("{photoId}")
        album_photo_by_id_resource.add_method(
            "DELETE",
            album_integration,
            authorizer=cognito_authorizer,
            authorization_type=apigateway.AuthorizationType.COGNITO,
        )

        # POST /albums/{albumId}/links — create share link (auth required)
        album_links_resource = album_by_id_resource.add_resource("links")
        album_links_resource.add_method(
            "POST",
            album_integration,
            authorizer=cognito_authorizer,
            authorization_type=apigateway.AuthorizationType.COGNITO,
        )

        # DELETE /albums/{albumId}/links/{token} — deactivate link (auth required)
        album_link_by_token_resource = album_links_resource.add_resource("{token}")
        album_link_by_token_resource.add_method(
            "DELETE",
            album_integration,
            authorizer=cognito_authorizer,
            authorization_type=apigateway.AuthorizationType.COGNITO,
        )

        # GET /a/{token} — PUBLIC: resolve share link (NO auth required)
        a_resource = api.root.add_resource("a")
        a_token_resource = a_resource.add_resource("{token}")
        a_token_resource.add_method(
            "GET",
            album_integration,
            # No authorizer — this is the public share link endpoint.
        )

        # ── CloudFormation Outputs ────────────────────────────────────────────

        CfnOutput(
            self,
            "PhotoSyncBucketName",
            value=bucket.bucket_name,
            description="S3 bucket for proxy images, curve files, and thread exports",
            export_name="HoehnPhotos-SyncBucketName",
        )

        CfnOutput(
            self,
            "ThreadEntryTableName",
            value=table.table_name,
            description="DynamoDB table for per-photo editorial thread entries",
            export_name="HoehnPhotos-ThreadTableName",
        )

        CfnOutput(
            self,
            "CatalogTableName",
            value=catalog_table.table_name,
            description="DynamoDB table for full catalog sync (photos, jobs, people, faces, revisions)",
            export_name="HoehnPhotos-CatalogTableName",
        )

        CfnOutput(
            self,
            "AlbumsTableName",
            value=albums_table.table_name,
            description="DynamoDB table for shared photo albums (single-table: META + PHOTO# items)",
            export_name="HoehnPhotos-AlbumsTableName",
        )

        CfnOutput(
            self,
            "ShareLinksTableName",
            value=share_links_table.table_name,
            description="DynamoDB table for album share link tokens",
            export_name="HoehnPhotos-ShareLinksTableName",
        )

        CfnOutput(
            self,
            "SyncApiEndpoint",
            value=api.url,
            description=(
                "API Gateway invoke URL. "
                "Endpoints: /sync/presign, /sync/catalog, /sync/threads, "
                "/sync/status/{canonicalId}, /restore/manifest, /albums, /a/{token}."
            ),
            export_name="HoehnPhotos-SyncApiEndpoint",
        )

        CfnOutput(
            self,
            "UserPoolId",
            value=self._auth_construct.user_pool_id,
            description="Cognito User Pool ID for Swift app configuration",
            export_name="HoehnPhotos-UserPoolId",
        )

        CfnOutput(
            self,
            "UserPoolClientId",
            value=self._auth_construct.user_pool_client_id,
            description="Cognito User Pool Client ID for Swift app configuration",
            export_name="HoehnPhotos-UserPoolClientId",
        )
