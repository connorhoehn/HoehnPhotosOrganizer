#!/bin/bash
# configure-app.sh — Write deployed AWS config into the app's UserDefaults
#
# Usage:
#   cd infra && ./scripts/configure-app.sh
#
# This writes the API endpoint, Cognito User Pool ID, and Client ID
# into the app's UserDefaults plist so you don't have to type them manually.
# The app reads these on launch from CognitoAuthManager and SyncSettingsView.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
cd "$INFRA_DIR"

if [ ! -f "outputs.json" ]; then
    echo "❌ outputs.json not found. Run ./scripts/deploy.sh first."
    exit 1
fi

API_ENDPOINT=$(python3 -c "import json; d=json.load(open('outputs.json')); print(d['HoehnPhotosSync']['SyncApiEndpoint'])")
USER_POOL_ID=$(python3 -c "import json; d=json.load(open('outputs.json')); print(d['HoehnPhotosSync']['UserPoolId'])")
CLIENT_ID=$(python3 -c "import json; d=json.load(open('outputs.json')); print(d['HoehnPhotosSync']['UserPoolClientId'])")
REGION=$(echo "$USER_POOL_ID" | cut -d_ -f1)

BUNDLE_ID="connorhoehn.com.HoehnPhotosOrganizer"
PLIST_PATH="$HOME/Library/Preferences/${BUNDLE_ID}.plist"

echo "═══ HoehnPhotos — Configure App ═══"
echo ""
echo "Writing to: $PLIST_PATH"
echo ""

defaults write "$BUNDLE_ID" syncAPIEndpoint "$API_ENDPOINT"
defaults write "$BUNDLE_ID" syncEnabled -bool true
defaults write "$BUNDLE_ID" "cognito.userPoolId" "$USER_POOL_ID"
defaults write "$BUNDLE_ID" "cognito.clientId" "$CLIENT_ID"
defaults write "$BUNDLE_ID" "cognito.region" "$REGION"

echo "  syncAPIEndpoint  = $API_ENDPOINT"
echo "  syncEnabled      = true"
echo "  cognito.userPoolId = $USER_POOL_ID"
echo "  cognito.clientId   = $CLIENT_ID"
echo "  cognito.region     = $REGION"
echo ""
echo "✓ App configured. Launch HoehnPhotosOrganizer and sign in from Settings > Sync."
