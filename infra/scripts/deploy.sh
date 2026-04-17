#!/bin/bash
# deploy.sh — Deploy the HoehnPhotos sync stack to AWS
#
# Prerequisites:
#   - AWS CLI configured (aws configure)
#   - Node.js installed (for CDK)
#   - CDK CLI installed (npm install -g aws-cdk)
#
# Usage:
#   cd infra && ./scripts/deploy.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
cd "$INFRA_DIR"

echo "═══ HoehnPhotos Sync — Deploy ═══"
echo ""

# Check prerequisites
command -v aws >/dev/null 2>&1 || { echo "❌ AWS CLI not found. Install: brew install awscli"; exit 1; }
command -v cdk >/dev/null 2>&1 || { echo "❌ CDK CLI not found. Install: npm install -g aws-cdk"; exit 1; }

# Check AWS credentials
if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "❌ AWS credentials not configured. Run: aws configure"
    exit 1
fi

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
echo "Account: $ACCOUNT"
echo "Region:  $REGION"
echo ""

# Activate venv
if [ -d ".venv" ]; then
    source .venv/bin/activate
else
    echo "Creating Python venv..."
    python3 -m venv .venv
    source .venv/bin/activate
    pip install -q -r requirements.txt
fi

# Bootstrap CDK (idempotent — safe to run multiple times)
echo "Bootstrapping CDK..."
cdk bootstrap aws://$ACCOUNT/$REGION --quiet 2>/dev/null || true

# Synth and deploy
echo ""
echo "Deploying stack..."
cdk deploy HoehnPhotosSync --require-approval never --outputs-file outputs.json

echo ""
echo "═══ Deploy complete ═══"
echo ""

# Parse outputs
API_ENDPOINT=$(python3 -c "import json; d=json.load(open('outputs.json')); print(d['HoehnPhotosSync']['SyncApiEndpoint'])")
USER_POOL_ID=$(python3 -c "import json; d=json.load(open('outputs.json')); print(d['HoehnPhotosSync']['UserPoolId'])")
CLIENT_ID=$(python3 -c "import json; d=json.load(open('outputs.json')); print(d['HoehnPhotosSync']['UserPoolClientId'])")
BUCKET=$(python3 -c "import json; d=json.load(open('outputs.json')); print(d['HoehnPhotosSync']['PhotoSyncBucketName'])")

echo "API Endpoint:    $API_ENDPOINT"
echo "User Pool ID:    $USER_POOL_ID"
echo "Client ID:       $CLIENT_ID"
echo "S3 Bucket:       $BUCKET"
echo ""
echo "Next: Run ./scripts/create-user.sh your@email.com"
