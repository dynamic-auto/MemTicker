#!/bin/bash
#
# Builds MemTicker.app and packages it as build/MemTicker.dmg.
#
#   ./build.sh
#
# Requires only the Xcode Command Line Tools:  xcode-select --install
#
set -euo pipefail

APP_NAME="MemTicker"
BUNDLE_ID="com.local.memticker"
SOURCE="Sources/MemTicker.swift"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

# Version comes from the latest git tag (v1.2.3 -> 1.2.3), or $VERSION, or 0.0.0.
if [ -z "${VERSION:-}" ]; then
  VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
  VERSION="${VERSION:-0.0.0}"
fi

if [ ! -f "$SOURCE" ]; then
  echo "error: $SOURCE not found — run this from the repository root" >&2
  exit 1
fi

echo "==> Building $APP_NAME $VERSION"
rm -rf "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling (universal: arm64 + x86_64)"
swiftc -O -target arm64-apple-macos12.0 -framework AppKit \
       -o "$BUILD_DIR/${APP_NAME}_arm64" "$SOURCE"
swiftc -O -target x86_64-apple-macos12.0 -framework AppKit \
       -o "$BUILD_DIR/${APP_NAME}_x86_64" "$SOURCE"
lipo -create -output "$APP/Contents/MacOS/$APP_NAME" \
     "$BUILD_DIR/${APP_NAME}_arm64" "$BUILD_DIR/${APP_NAME}_x86_64"
rm -f "$BUILD_DIR/${APP_NAME}_arm64" "$BUILD_DIR/${APP_NAME}_x86_64"

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>LSMinimumSystemVersion</key>    <string>12.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing"
# Strip extended attributes first: iCloud-synced and downloaded working
# copies leave FinderInfo on the bundle, which codesign refuses to sign.
xattr -cr "$APP"
codesign --force --sign - --timestamp=none "$APP"

echo "==> Creating disk image"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$BUILD_DIR/$APP_NAME.dmg" >/dev/null
rm -rf "$STAGE"

echo
echo "Done."
echo "  App:  $APP"
echo "  DMG:  $BUILD_DIR/$APP_NAME.dmg"
