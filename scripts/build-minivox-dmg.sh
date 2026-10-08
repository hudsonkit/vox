#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
MINIVOX_DIR="$ROOT/apps/minivox"
BUILD_DIR="$ROOT/dist/minivox"
APP_NAME="Minivox.app"
DMG_NAME="Minivox.dmg"
BUNDLE="$BUILD_DIR/$APP_NAME"
SITE_DOWNLOAD="$ROOT/site/public/downloads/$DMG_NAME"
DEFAULT_VERSION="$(sed -n 's/  "version": "\(.*\)",/\1/p' "$ROOT/packages/cli/package.json" | head -n 1)"
VERSION="${MINIVOX_VERSION:-$DEFAULT_VERSION}"
SIGN_IDENTITY="${MINIVOX_SIGN_IDENTITY:--}"
NOTARY_PROFILE="${MINIVOX_NOTARY_PROFILE:-}"
REQUIRE_SIGNED_RELEASE="${MINIVOX_REQUIRE_SIGNED_RELEASE:-}"
PUBLISH_SITE_DOWNLOAD="${MINIVOX_PUBLISH_SITE_DOWNLOAD:-0}"

if [ -n "$REQUIRE_SIGNED_RELEASE" ]; then
    if [ "$SIGN_IDENTITY" = "-" ] || [ -z "$NOTARY_PROFILE" ]; then
        echo "Signed Minivox releases require MINIVOX_SIGN_IDENTITY and MINIVOX_NOTARY_PROFILE." >&2
        exit 1
    fi
fi

echo "==> Building Minivox release binary..."
swift build --package-path "$MINIVOX_DIR" -c release

PRODUCTS_DIR="$MINIVOX_DIR/.build/release"
EXECUTABLE="$PRODUCTS_DIR/Minivox"
COMMAND_EXECUTABLE="$PRODUCTS_DIR/MinivoxCommand"
if [ ! -x "$EXECUTABLE" ]; then
    echo "Minivox release executable was not produced at $EXECUTABLE." >&2
    exit 1
fi
if [ ! -x "$COMMAND_EXECUTABLE" ]; then
    echo "Minivox command executable was not produced at $COMMAND_EXECUTABLE." >&2
    exit 1
fi

echo "==> Creating Minivox.app..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$EXECUTABLE" "$BUNDLE/Contents/MacOS/Minivox"
cp "$COMMAND_EXECUTABLE" "$BUNDLE/Contents/MacOS/MinivoxCommand"

while IFS= read -r -d '' RESOURCES; do
    cp -R "$RESOURCES" "$BUNDLE/Contents/Resources/"
    echo "    Bundled $(basename "$RESOURCES")"
done < <(find -L "$PRODUCTS_DIR" -maxdepth 1 -type d -name "*.bundle" -print0)

ICON_SOURCE="$ROOT/apps/vox/Vox/Assets.xcassets/AppIcon.appiconset"
ICON_WORK_DIR="$(mktemp -d)"
DMG_STAGING="$(mktemp -d)"
cleanup() {
    rm -rf "$ICON_WORK_DIR" "$DMG_STAGING"
}
trap cleanup EXIT

if [ -d "$ICON_SOURCE" ]; then
    ICONSET="$ICON_WORK_DIR/Minivox.iconset"
    mkdir -p "$ICONSET"
    cp "$ICON_SOURCE"/icon_*.png "$ICONSET/"
    iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/Minivox.icns"
fi

cat > "$BUILD_DIR/Minivox.entitlements" << 'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
ENTITLEMENTS

cat > "$BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Minivox</string>
    <key>CFBundleDisplayName</key>
    <string>Minivox</string>
    <key>CFBundleIdentifier</key>
    <string>cc.voxd.minivox</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>Minivox</string>
    <key>CFBundleIconFile</key>
    <string>Minivox</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSMultipleInstancesProhibited</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Minivox uses the microphone to turn your dictation into text.</string>
</dict>
</plist>
PLIST

if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "==> Ad hoc signing Minivox.app..."
    codesign --force --sign - "$BUNDLE/Contents/MacOS/MinivoxCommand"
    codesign --force --sign - "$BUNDLE/Contents/MacOS/Minivox"
    codesign --force --sign - \
        --entitlements "$BUILD_DIR/Minivox.entitlements" \
        "$BUNDLE"
else
    echo "==> Signing Minivox.app with Developer ID..."
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" \
        "$BUNDLE/Contents/MacOS/MinivoxCommand"
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" \
        "$BUNDLE/Contents/MacOS/Minivox"
    codesign --force --options runtime --timestamp \
        --entitlements "$BUILD_DIR/Minivox.entitlements" \
        --sign "$SIGN_IDENTITY" \
        "$BUNDLE"
fi

codesign --verify --deep --strict --verbose=2 "$BUNDLE"

echo "==> Creating Minivox.dmg..."
cp -R "$BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create \
    -volname "Minivox" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$BUILD_DIR/$DMG_NAME"

if [ "$SIGN_IDENTITY" != "-" ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$BUILD_DIR/$DMG_NAME"
fi

if [ "$SIGN_IDENTITY" != "-" ] && [ -n "$NOTARY_PROFILE" ]; then
    echo "==> Notarizing Minivox.dmg..."
    xcrun notarytool submit "$BUILD_DIR/$DMG_NAME" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    xcrun stapler staple "$BUILD_DIR/$DMG_NAME"
else
    echo "==> Skipping notarization (a notary profile was not provided)."
fi

hdiutil verify "$BUILD_DIR/$DMG_NAME"
if [ -n "$REQUIRE_SIGNED_RELEASE" ]; then
    spctl --assess --type open --context context:primary-signature -v "$BUILD_DIR/$DMG_NAME" 2>&1
else
    spctl --assess --type open --context context:primary-signature -v "$BUILD_DIR/$DMG_NAME" 2>&1 || true
fi

if [ "$PUBLISH_SITE_DOWNLOAD" = "1" ]; then
    mkdir -p "$(dirname "$SITE_DOWNLOAD")"
    cp "$BUILD_DIR/$DMG_NAME" "$SITE_DOWNLOAD"
    echo "==> Website download: $SITE_DOWNLOAD"
fi

echo "==> Done: $BUILD_DIR/$DMG_NAME"
ls -lh "$BUILD_DIR/$DMG_NAME"
shasum -a 256 "$BUILD_DIR/$DMG_NAME"
