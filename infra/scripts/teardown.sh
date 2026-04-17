#!/bin/bash
# teardown.sh — Destroy the HoehnPhotos sync stack
#
# Usage:
#   cd infra && ./scripts/teardown.sh
#
# WARNING: DynamoDB tables and S3 bucket have RETAIN policy —
# they will NOT be deleted by cdk destroy. You must manually
# delete them from the AWS Console if you want full cleanup.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
cd "$INFRA_DIR"

echo "═══ HoehnPhotos — Teardown ═══"
echo ""
echo "⚠️  This will destroy Lambda functions and API Gateway."
echo "    DynamoDB tables and S3 bucket are RETAINED (not deleted)."
echo ""
read -p "Continue? (y/N) " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Cancelled."
    exit 0
fi

source .venv/bin/activate 2>/dev/null || true
cdk destroy HoehnPhotosSync --force

echo ""
echo "✓ Stack destroyed."
echo "  DynamoDB tables and S3 bucket are retained in your account."
echo "  Delete them manually from the AWS Console if needed."
