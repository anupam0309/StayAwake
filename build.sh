#!/bin/bash
# Builds StayAwake.app with the Command Line Tools only (no Xcode needed).
#   ./build.sh            build into ./StayAwake.app
#   ./build.sh --install  build, copy to /Applications, and open it
#   ./build.sh --icon     re-render Resources/AppIcon.icns first
set -euo pipefail
cd "$(dirname "$0")"

APP="StayAwake.app"
BIN="$APP/Contents/MacOS/StayAwake"
ICON="Resources/AppIcon.icns"
INSTALL=0; REICON=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --icon) REICON=1 ;;
        *) echo "unknown option: $arg"; exit 2 ;;
    esac
done

if [[ $REICON -eq 1 || ! -f "$ICON" ]]; then
    echo "Rendering icon..."
    swift Tools/make-icon.swift "$ICON" docs/icon.png
fi

pkill -x StayAwake 2>/dev/null || true

echo "Cleaning..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

echo "Writing Info.plist..."
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Stay Awake</string>
    <key>CFBundleDisplayName</key>
    <string>Stay Awake</string>
    <key>CFBundleExecutable</key>
    <string>StayAwake</string>
    <key>CFBundleIdentifier</key>
    <string>com.anupam0309.stayawake</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <!-- Menu bar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "Compiling..."
swiftc -swift-version 5 -O -parse-as-library \
    -framework Cocoa \
    -framework SwiftUI \
    -framework IOKit \
    -framework ServiceManagement \
    -framework UserNotifications \
    -o "$BIN" \
    Sources/StayAwake.swift

echo "Signing (ad-hoc)..."
codesign --force --sign - "$APP"

echo
echo "Built $(pwd)/$APP"
if [[ $INSTALL -eq 1 ]]; then
    echo "Installing to /Applications..."
    rm -rf /Applications/StayAwake.app
    cp -R "$APP" /Applications/
    open /Applications/StayAwake.app
    echo "Running. Look for the moon icon in the menu bar."
else
    echo "Run it with:  open '$(pwd)/$APP'"
fi
