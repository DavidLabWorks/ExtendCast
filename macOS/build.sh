#!/bin/bash

# Exit on error
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SCRIPT_DIR"

VERSION="v1.0.0"
ARCHITECTURES=("arm64" "x86_64")
BUILD_NUMBER_FILE="$SCRIPT_DIR/BuildNumber"

CURRENT_BUILD="$(tr -d '[:space:]' < "$BUILD_NUMBER_FILE")"
if ! [[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
    echo "Error: BuildNumber must contain a non-negative integer, got '$CURRENT_BUILD'."
    exit 1
fi
BUILD_NUMBER=$((CURRENT_BUILD + 1))

# Stable local signing identity. Override with SIGN_IDENTITY=- for ad-hoc builds.
SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development: ruobin521@gmail.com (JWP5TQ78Q7)}"

echo "============================================"
echo "  Building ExtendCast $VERSION (Build $BUILD_NUMBER, Universal 2)"
echo "============================================"
mkdir -p ".build/swiftpm-cache" ".build/swiftpm-config" ".build/swiftpm-security"

for ARCH in "${ARCHITECTURES[@]}"; do
    MODULE_CACHE="$PWD/.build/module-cache-$ARCH"
    mkdir -p "$MODULE_CACHE"
    echo "Building $ARCH..."
    CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
    SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
    swift build -c release --product BetterCastSender --arch "$ARCH" \
        --disable-sandbox \
        --cache-path ".build/swiftpm-cache" \
        --config-path ".build/swiftpm-config" \
        --security-path ".build/swiftpm-security" \
        --manifest-cache local
done

# Define Paths
APP_NAME="ExtendCast.app"
ZIP_NAME="ExtendCast-${VERSION}-universal.zip"
UNIVERSAL_BINARY=".build/BetterCastSender-universal"
SIDEBAR_ICON_SOURCE="Sources/BetterCastSender/Resources/SidebarIcons"

# Clean the previous app and any legacy packaging artifacts.
rm -rf "$APP_NAME" "BetterCast.app" "BetterCastSender.app" "dmg_staging" "BetterCast.dmg" "$ZIP_NAME"
rm -f "$UNIVERSAL_BINARY"

echo "Creating Universal 2 executable..."
lipo -create \
    ".build/arm64-apple-macosx/release/BetterCastSender" \
    ".build/x86_64-apple-macosx/release/BetterCastSender" \
    -output "$UNIVERSAL_BINARY"

# ============================================
# ExtendCast App (unified sender + receiver)
# ============================================
echo "Creating $APP_NAME..."
mkdir -p "$APP_NAME/Contents/MacOS"
mkdir -p "$APP_NAME/Contents/Resources"
# Binary is still named BetterCastSender from the Swift package target.
cp "$UNIVERSAL_BINARY" "$APP_NAME/Contents/MacOS/BetterCastSender"
cp "Info.plist" "$APP_NAME/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_NAME/Contents/Info.plist"
cp "$REPO_ROOT/Shared/Branding/BetterCastIcon.icns" "$APP_NAME/Contents/Resources/AppIcon.icns"
ditto "$SIDEBAR_ICON_SOURCE" "$APP_NAME/Contents/Resources/SidebarIcons"

if [ ! -f "$APP_NAME/Contents/Resources/SidebarIcons/sidebar-sender.svg" ]; then
    echo "Error: sidebar icon resources were not packaged."
    exit 1
fi

# Code sign with entitlements
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" --entitlements "ExtendCast.entitlements" "$APP_NAME"

echo "Creating release archive..."
ditto -c -k --sequesterRsrc --keepParent "$APP_NAME" "$ZIP_NAME"
unzip -t "$ZIP_NAME" >/dev/null
if ! unzip -Z1 "$ZIP_NAME" | grep -Fq "$APP_NAME/Contents/Resources/SidebarIcons/sidebar-sender.svg"; then
    echo "Error: release archive is missing sidebar icon resources."
    exit 1
fi
printf '%s\n' "$BUILD_NUMBER" > "$BUILD_NUMBER_FILE"

echo ""
echo "============================================"
echo "  Build Complete!"
echo "============================================"
echo "App:"
echo "  - $APP_NAME ($(lipo -archs "$APP_NAME/Contents/MacOS/BetterCastSender"))"
echo "  - $ZIP_NAME"
echo "  - Signed: $SIGN_IDENTITY"
echo ""
echo "Installation:"
echo "  1. Copy ExtendCast.app to Applications"
echo "  2. Grant Screen Recording permission when prompted"
echo "  3. Grant Accessibility permission when prompted"
