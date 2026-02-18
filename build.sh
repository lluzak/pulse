#!/bin/bash
set -e

# Configuration
APP_NAME="Pulse"
SCHEME="pulse"
BUILD_DIR="build"
DMG_NAME="Pulse"
VERSION=$(xcodebuild -scheme "${SCHEME}" -showBuildSettings 2>/dev/null | grep MARKETING_VERSION | head -1 | awk '{print $3}')

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Building ${APP_NAME} ===${NC}"
echo "Version: ${VERSION}"
echo ""

# Clean build directory
echo -e "${YELLOW}Cleaning build directory...${NC}"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

# Build Release version
echo -e "${YELLOW}Building Release version...${NC}"
xcodebuild -scheme "${SCHEME}" \
    -configuration Release \
    -derivedDataPath "${BUILD_DIR}/DerivedData" \
    -destination 'platform=macOS' \
    clean build 2>&1 | grep -E "(error:|warning:|BUILD SUCCEEDED|BUILD FAILED)" | tail -20

# Check if build succeeded
APP_PATH="${BUILD_DIR}/DerivedData/Build/Products/Release/${APP_NAME}.app"
if [ ! -d "${APP_PATH}" ]; then
    echo -e "${RED}Build failed! App not found at ${APP_PATH}${NC}"
    exit 1
fi

echo -e "${GREEN}Build succeeded!${NC}"
echo "App location: ${APP_PATH}"

# Create DMG directory structure
echo -e "${YELLOW}Creating DMG structure...${NC}"
DMG_TEMP="${BUILD_DIR}/dmg_temp"
rm -rf "${DMG_TEMP}"
mkdir -p "${DMG_TEMP}"

# Copy app to DMG temp
cp -R "${APP_PATH}" "${DMG_TEMP}/"

# Create Applications symlink
ln -s /Applications "${DMG_TEMP}/Applications"

# Create DMG
echo -e "${YELLOW}Creating DMG...${NC}"
DMG_PATH="${BUILD_DIR}/${DMG_NAME}-${VERSION}.dmg"
rm -f "${DMG_PATH}"

hdiutil create -volname "${APP_NAME}" \
    -srcfolder "${DMG_TEMP}" \
    -ov -format UDZO \
    "${DMG_PATH}"

# Clean up temp directory
rm -rf "${DMG_TEMP}"

echo ""
echo -e "${GREEN}=== Build Complete ===${NC}"
echo -e "DMG created: ${DMG_PATH}"
echo ""

# Show DMG size
DMG_SIZE=$(du -h "${DMG_PATH}" | cut -f1)
echo "DMG Size: ${DMG_SIZE}"

# Open build folder
open "${BUILD_DIR}"
