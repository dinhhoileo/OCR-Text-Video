#!/bin/bash
set -e

# ──────────────────────────────────────────────
# VideoOCR macOS — Build & Package as DMG
# ──────────────────────────────────────────────

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="VideoOCR"
SCHEME="VideoOCRMac"
BUILD_DIR="${PROJECT_DIR}/build/macos-release"
DIST_DIR="${PROJECT_DIR}/dist"
APP_PATH="${DIST_DIR}/${APP_NAME}.app"
DMG_NAME="${APP_NAME}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
DMG_TEMP="${DIST_DIR}/${APP_NAME}-temp.dmg"
DMG_VOLUME="${APP_NAME}"

echo "🔨 Step 1: Generating Xcode project..."
cd "${PROJECT_DIR}"
xcodegen generate --spec VideoOCRMacProject.yml

echo "🧹 Step 1.5: Cleaning previous build..."
rm -rf "${BUILD_DIR}"

echo "🏗️  Step 2: Building ${SCHEME} (Release)..."
xcodebuild -project "${SCHEME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -derivedDataPath "${BUILD_DIR}" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    clean build 2>&1 | tail -10

# Find the built .app
BUILT_APP=$(find "${BUILD_DIR}" -name "${APP_NAME}.app" -type d | head -1)
if [ -z "$BUILT_APP" ]; then
    echo "❌ Error: Could not find built ${APP_NAME}.app in ${BUILD_DIR}"
    echo "   Searching entire build directory:"
    find "${BUILD_DIR}" -name "*.app" -type d
    exit 1
fi

echo "✅ Found app at: ${BUILT_APP}"

echo "📦 Step 3: Copying app to dist..."
rm -rf "${APP_PATH}"
mkdir -p "${DIST_DIR}"
cp -R "${BUILT_APP}" "${APP_PATH}"

echo "🧹 Step 3.5: Cleaning resource forks & extended attributes..."
xattr -cr "${APP_PATH}" 2>/dev/null || true

echo "🔏 Step 4: Ad-hoc code signing..."
codesign --force --deep --sign - "${APP_PATH}"

echo "✅ App ready at: ${APP_PATH}"

# ──────────────────────────────────────────────
# Create DMG
# ──────────────────────────────────────────────

echo "💿 Step 5: Creating DMG..."
rm -f "${DMG_TEMP}" "${DMG_PATH}"

# Create a temporary DMG
hdiutil create \
    -srcfolder "${APP_PATH}" \
    -volname "${DMG_VOLUME}" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    "${DMG_TEMP}"

# Mount it
MOUNT_POINT=$(hdiutil attach -readwrite -noverify -noautoopen "${DMG_TEMP}" | grep -oE '/Volumes/[^ ]+')
echo "   Mounted at: ${MOUNT_POINT}"

# Add a symlink to /Applications for drag-to-install
ln -sf /Applications "${MOUNT_POINT}/Applications"

# Unmount
sync
sleep 2
hdiutil detach "${MOUNT_POINT}" || hdiutil detach -force "${MOUNT_POINT}" 2>/dev/null
sleep 3

# Convert to compressed read-only DMG
hdiutil convert "${DMG_TEMP}" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "${DMG_PATH}"

rm -f "${DMG_TEMP}"

echo ""
echo "══════════════════════════════════════════"
echo "✅ DMG created successfully!"
echo "📍 Location: ${DMG_PATH}"
echo "📏 Size: $(du -h "${DMG_PATH}" | cut -f1)"
echo "══════════════════════════════════════════"
echo ""
echo "📋 To distribute:"
echo "   1. Send the DMG file to others"
echo "   2. They open the DMG"
echo "   3. Drag VideoOCR.app to Applications"
echo "   4. First launch: Right-click → Open (to bypass Gatekeeper)"
