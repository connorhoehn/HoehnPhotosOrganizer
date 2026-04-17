#!/bin/bash
# status.sh — Check the deployed stack status and health
#
# Usage:
#   cd infra && ./scripts/status.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
cd "$INFRA_DIR"

echo "═══ HoehnPhotos — Stack Status ═══"
echo ""

# Check if outputs exist
if [ ! -f "outputs.json" ]; then
    echo "❌ Not deployed. Run ./scripts/deploy.sh"
    exit 1
fi

API_ENDPOINT=$(python3 -c "import json; d=json.load(open('outputs.json')); print(d['HoehnPhotosSync']['SyncApiEndpoint'])")
USER_POOL_ID=$(python3 -c "import json; d=json.load(open('outputs.json')); print(d['HoehnPhotosSync']['UserPoolId'])")
BUCKET=$(python3 -c "import json; d=json.load(open('outputs.json')); print(d['HoehnPhotosSync']['PhotoSyncBucketName'])")

echo "API:     $API_ENDPOINT"
echo "Pool:    $USER_POOL_ID"
echo "Bucket:  $BUCKET"
echo ""

# Health check
echo -n "Health:  "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${API_ENDPOINT}health" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    echo "✓ OK (200)"
else
    echo "❌ Unreachable ($HTTP_CODE)"
fi

# S3 object count
echo -n "Proxies: "
COUNT=$(aws s3 ls "s3://$BUCKET/proxies/" --summarize 2>/dev/null | grep "Total Objects" | awk '{print $3}' || echo "?")
echo "$COUNT objects"

# Cognito user count
echo -n "Users:   "
USER_COUNT=$(aws cognito-idp list-users --user-pool-id "$USER_POOL_ID" --query 'length(Users)' --output text 2>/dev/null || echo "?")
echo "$USER_COUNT"

echo ""
