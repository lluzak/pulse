#!/bin/bash
set -e

# Notarization script for Pulse
# Requires: Apple Developer account, app-specific password stored in keychain
#
# Setup (one-time):
# 1. Create app-specific password at appleid.apple.com
# 2. Store in keychain:
#    xcrun notarytool store-credentials "pulse-notarize" \
#        --apple-id "your@email.com" \
#        --team-id "YOUR_TEAM_ID" \
#        --password "app-specific-password"

# Configuration
APP_NAME="Pulse"
BUNDLE_ID="plusar.pulse"  # Update to match your bundle ID
KEYCHAIN_PROFILE="pulse-notarize"
BUILD_DIR="build"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Find the DMG
DMG_PATH=$(ls -t ${BUILD_DIR}/*.dmg 2>/dev/null | head -1)

if [ -z "${DMG_PATH}" ]; then
    echo -e "${RED}No DMG found in ${BUILD_DIR}/${NC}"
    echo "Run ./build.sh first to create the DMG"
    exit 1
fi

echo -e "${GREEN}=== Notarizing ${APP_NAME} ===${NC}"
echo "DMG: ${DMG_PATH}"
echo ""

# Submit for notarization
echo -e "${YELLOW}Submitting for notarization...${NC}"
xcrun notarytool submit "${DMG_PATH}" \
    --keychain-profile "${KEYCHAIN_PROFILE}" \
    --wait

# Staple the notarization ticket
echo -e "${YELLOW}Stapling notarization ticket...${NC}"
xcrun stapler staple "${DMG_PATH}"

echo ""
echo -e "${GREEN}=== Notarization Complete ===${NC}"
echo "DMG is ready for distribution: ${DMG_PATH}"

# Verify
echo ""
echo -e "${YELLOW}Verifying notarization...${NC}"
spctl -a -t open --context context:primary-signature -v "${DMG_PATH}"
