#!/bin/bash
# create-user.sh — Create a Cognito user for HoehnPhotos
#
# Usage:
#   cd infra && ./scripts/create-user.sh your@email.com
#
# The user will be created with a temporary password.
# On first sign-in in the app, they'll be prompted to set a new password.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
cd "$INFRA_DIR"

EMAIL="${1:-}"
if [ -z "$EMAIL" ]; then
    echo "Usage: ./scripts/create-user.sh your@email.com"
    exit 1
fi

# Read outputs from deploy
if [ ! -f "outputs.json" ]; then
    echo "❌ outputs.json not found. Run ./scripts/deploy.sh first."
    exit 1
fi

USER_POOL_ID=$(python3 -c "import json; d=json.load(open('outputs.json')); print(d['HoehnPhotosSync']['UserPoolId'])")

# Generate a temporary password
TEMP_PASSWORD="Temp$(openssl rand -hex 4)!"

echo "═══ HoehnPhotos — Create User ═══"
echo ""
echo "Email:          $EMAIL"
echo "User Pool:      $USER_POOL_ID"
echo "Temp Password:  $TEMP_PASSWORD"
echo ""

aws cognito-idp admin-create-user \
    --user-pool-id "$USER_POOL_ID" \
    --username "$EMAIL" \
    --user-attributes Name=email,Value="$EMAIL" Name=email_verified,Value=true \
    --temporary-password "$TEMP_PASSWORD" \
    --message-action SUPPRESS \
    --output text --query 'User.Username'

echo ""
echo "✓ User created."
echo ""
echo "Sign in from the app with:"
echo "  Email:     $EMAIL"
echo "  Password:  $TEMP_PASSWORD"
echo ""
echo "You'll be prompted to set a new password on first login."
