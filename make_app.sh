#!/bin/bash

# Exit on error
set -e

VERSION="v15.1-custom"

# Stable local signing identity. Override with SIGN_IDENTITY=- for ad-hoc builds.
SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development: ruobin521@gmail.com (JWP5TQ78Q7)}"

echo "============================================"
echo "  Building BetterCast $VERSION (Apple Silicon)"
echo "============================================"
mkdir -p ".build/module-cache" ".build/swiftpm-cache" ".build/swiftpm-config" ".build/swiftpm-security"
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
swift build -c release --product BetterCastSender --arch arm64 \
    --disable-sandbox \
    --cache-path ".build/swiftpm-cache" \
    --config-path ".build/swiftpm-config" \
    --security-path ".build/swiftpm-security" \
    --manifest-cache local

# Define Paths
BUILD_DIR=".build/arm64-apple-macosx/release"
APP_NAME="BetterCast.app"

# Clean the previous app and any legacy packaging artifacts.
rm -rf "$APP_NAME" "BetterCastSender.app" "dmg_staging" "BetterCast.dmg" "BetterCast-v15.1-custom.zip"

# ============================================
# BetterCast App (unified sender + receiver)
# ============================================
echo "Creating $APP_NAME..."
mkdir -p "$APP_NAME/Contents/MacOS"
mkdir -p "$APP_NAME/Contents/Resources"
# Binary is still named BetterCastSender from the Swift package target.
cp "$BUILD_DIR/BetterCastSender" "$APP_NAME/Contents/MacOS/BetterCastSender"
cp "BetterCastSender-Info.plist" "$APP_NAME/Contents/Info.plist"
cp "assets/branding/BetterCastIcon.icns" "$APP_NAME/Contents/Resources/AppIcon.icns"

# Code sign with entitlements
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" --entitlements "BetterCastSender-Release.entitlements" "$APP_NAME"

echo ""
echo "============================================"
echo "  Build Complete!"
echo "============================================"
echo "App:"
echo "  - $APP_NAME (signed: $SIGN_IDENTITY)"
echo ""
echo "Installation:"
echo "  1. Copy BetterCast.app to Applications"
echo "  2. Grant Screen Recording permission when prompted"
echo "  3. Grant Accessibility permission when prompted"
