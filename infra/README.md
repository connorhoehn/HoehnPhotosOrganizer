# HoehnPhotos Cloud Sync Infrastructure

AWS CDK stack (Python) for HoehnPhotosOrganizer cloud sync and restore.

This is a **separate, independent stack** — it is not coupled to any other
existing AWS infrastructure. You can deploy it to any bootstrapped AWS account.

---

## Architecture

```
HoehnPhotosOrganizer (macOS app)
          |
          | presigned URL requests
          v
  API Gateway (REST)  ──>  Lambda: presigned URL generator
          |                     |
          |                     |── S3 GetObject / PutObject
          |                     └── DynamoDB PutItem / Query
          |
  S3 Private Bucket                DynamoDB Thread Table
  ├── proxies/                      PK: threadRootId (photo canonical_id)
  ├── curves/                       SK: "<timestamp>#<entryId>"
  ├── threads/                      GSI: byThreadRoot
  └── catalog/                      Billing: PAY_PER_REQUEST
```

**Wave implementation plan:**

| Wave | Plan  | What ships                                         |
|------|-------|----------------------------------------------------|
| 1    | 04-01 | Stack scaffold, S3 bucket, DynamoDB table, placeholders |
| 2    | 04-02 | Lambda: presigned URL, thread CRUD, auth (Cognito) |
| 3    | 04-03 | Swift SyncClient actor using generated API client  |
| 4    | 04-04 | Restore flow, batch replay, conflict resolution    |

---

## Prerequisites

- **AWS CLI** configured with credentials for your target account:
  ```bash
  aws configure
  # or
  aws sso login --profile your-profile
  ```

- **CDK CLI** installed globally:
  ```bash
  npm install -g aws-cdk
  cdk --version  # should be 2.x
  ```

- **Python 3.12+** (matches Lambda runtime):
  ```bash
  python3 --version
  ```

- **CDK bootstrapped** in your target region (one-time per account/region):
  ```bash
  cdk bootstrap aws://ACCOUNT_ID/us-east-1
  ```

---

## Setup

```bash
cd infra/
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

---

## Common Commands

### Generate CloudFormation template (no AWS calls)
```bash
cdk synth
```
Output: `cdk.out/HoehnPhotosSync.template.json`

### Preview changes against deployed stack
```bash
cdk diff
```

### Deploy to AWS
```bash
cdk deploy --context env=dev
```

Wave 1 deploys: S3 bucket, DynamoDB table, placeholder Lambda, placeholder API Gateway.

### Destroy all resources
```bash
cdk destroy
```

**Note:** S3 bucket and DynamoDB table have `RemovalPolicy.RETAIN` to protect photo data.
You must manually delete them from the AWS console after `cdk destroy` if needed.

---

## Stack Outputs

After `cdk deploy`, these outputs are printed and can be fetched via:
```bash
aws cloudformation describe-stacks \
  --stack-name HoehnPhotosSync \
  --query "Stacks[0].Outputs"
```

| Output Key              | Description                                           |
|-------------------------|-------------------------------------------------------|
| `PhotoSyncBucketName`   | S3 bucket name — add to Swift app `Info.plist`        |
| `ThreadEntryTableName`  | DynamoDB table name — inject into Lambda env vars     |
| `SyncApiEndpoint`       | API Gateway URL — base URL for Swift sync client      |

Example `Info.plist` entry (Wave 3):
```xml
<key>SyncAPIEndpoint</key>
<string>https://xxxx.execute-api.us-east-1.amazonaws.com/v1</string>
<key>SyncBucketName</key>
<string>hoehntphotossync-photostoragephotosyncbucketxxxxx</string>
```

---

## Context Variables

Override defaults via `--context key=value`:

| Key          | Default       | Description                          |
|--------------|---------------|--------------------------------------|
| `env`        | `dev`         | Environment tag (dev, staging, prod) |
| `region`     | `us-east-1`   | AWS region                           |
| `app_name`   | `HoehnPhotos` | Resource name prefix                 |
| `stack_name` | `HoehnPhotosSync` | CloudFormation stack name        |

---

## S3 Bucket Design

- **Versioning:** enabled — supports point-in-time recovery of proxies and curve files
- **Public access:** blocked — all access via presigned URLs from Lambda
- **Encryption:** SSE-S3 (AWS-managed keys)
- **Lifecycle:** incomplete multipart uploads expire after 7 days
- **Glacier archive:** documented but disabled — enable in Phase 8 archive workflow

**Asset prefixes** (set in `config.json`, enforced at Lambda layer):

| Prefix     | Content                              | Typical size   |
|------------|--------------------------------------|----------------|
| `proxies/` | JPEG proxy images (≤ 1600 px)        | ~1–2 MB each   |
| `curves/`  | Curve files (.acv, .csv, .lut)       | < 10 MB each   |
| `threads/` | Thread entry batch exports (JSON)    | < 1 MB/photo   |
| `catalog/` | SQLite catalog export snapshots      | Varies         |

---

## DynamoDB Thread Table Design

| Attribute    | Type   | Role               | Description                                        |
|--------------|--------|--------------------|----------------------------------------------------|
| threadRootId | String | Partition key      | Photo canonical_id (e.g. "IMG_1234.CR3")           |
| sortKey      | String | Sort key           | `"<timestamp>#<entryId>"` — chronological ordering |
| timestamp    | Number | GSI sort key       | Unix epoch seconds — for range queries             |
| ttl          | Number | TTL attribute      | Optional expiry — not enforced until Wave 4        |

**GSI: byThreadRoot**
- Purpose: "Fetch all entries for photo X since timestamp T, ascending"
- PK: `threadRootId`
- SK: `timestamp` (Number)
- Projection: ALL

---

## Security Notes

- The Lambda execution role has **minimum required permissions** (S3 GetObject/PutObject,
  DynamoDB PutItem/Query/BatchWriteItem).
- Wave 2 will add Cognito user pool authentication to API Gateway.
  Until then, the `/health` placeholder endpoint is unauthenticated.
- The S3 bucket has `EnforceSSL=true` — all HTTP requests return 403.
