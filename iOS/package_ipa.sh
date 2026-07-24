#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PRODUCT_NAME="BetterCastReceiverIOS"
TARGET_TRIPLE="arm64-apple-ios13.0"
BINARY_PATH="${BINARY_PATH:-$SCRIPT_DIR/.build/arm64-apple-ios/release/$PRODUCT_NAME}"
OUTPUT_DIR="$SCRIPT_DIR/dist"
OUTPUT_PATH="$OUTPUT_DIR/ExtendCast-iOS-unsigned.ipa"
STAGING_DIR="$(mktemp -d /tmp/extendcast-ios-package.XXXXXX)"
APP_DIR="$STAGING_DIR/Payload/$PRODUCT_NAME.app"

cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

echo "Building ExtendCast for iOS..."
cd "$SCRIPT_DIR"
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
swift build \
    --configuration release \
    --triple "$TARGET_TRIPLE" \
    --sdk "$SDK_PATH"

if [ ! -f "$BINARY_PATH" ]; then
    echo "Binary not found at $BINARY_PATH"
    exit 1
fi

mkdir -p "$APP_DIR/Frameworks" "$OUTPUT_DIR"
cp "$BINARY_PATH" "$APP_DIR/$PRODUCT_NAME"
cp "$SCRIPT_DIR/Sources/Info.plist" "$APP_DIR/Info.plist"
cp "$SCRIPT_DIR/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png" "$APP_DIR/AppIcon.png"

xcrun swift-stdlib-tool \
    --copy \
    --scan-executable "$APP_DIR/$PRODUCT_NAME" \
    --platform iphoneos \
    --destination "$APP_DIR/Frameworks"

rm -f "$OUTPUT_PATH"
(
    cd "$STAGING_DIR"
    zip -r -q "$OUTPUT_PATH" Payload
)

echo "Created unsigned IPA: $OUTPUT_PATH"
echo "Sign it with an Apple Development or Distribution profile before installation."
