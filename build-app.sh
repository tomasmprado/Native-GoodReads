#!/usr/bin/env bash
# Builds Goodreads.app using swiftc directly — no SwiftPM, no full Xcode needed.
# Command Line Tools (xcode-select --install) is enough.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Goodreads"
APP="$ROOT/$APP_NAME.app"
SRC="$ROOT/Sources/GoodreadsGUI"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"                       # arm64 or x86_64
TARGET="${ARCH}-apple-macos13.0"

echo "==> Compiling for $TARGET"
echo "    SDK: $SDK"

mkdir -p "$ROOT/.build"
swiftc \
    -O \
    -parse-as-library \
    -sdk "$SDK" \
    -target "$TARGET" \
    -o "$ROOT/.build/$APP_NAME" \
    "$SRC"/*.swift

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# Icon: build it from icon-source.png if we don't have an .icns yet.
if [ ! -f "$ROOT/AppIcon.icns" ] && [ -f "$ROOT/icon-source.png" ]; then
    bash "$ROOT/make-icon.sh" >/dev/null && echo "==> Built AppIcon.icns"
fi

ICON_KEY=""
if [ -f "$ROOT/AppIcon.icns" ]; then
    cp "$ROOT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    ICON_KEY="    <key>CFBundleIconFile</key>          <string>AppIcon</string>"
    echo "==> Icon included"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>        <string>local.goodreads.gui</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
$ICON_KEY
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "(codesign skipped)"

# The Dock and Finder cache icons aggressively; nudge them.
touch "$APP"

echo "==> Done: $APP"
open "$APP"
