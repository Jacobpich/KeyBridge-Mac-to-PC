#!/bin/zsh
# Builds "Keybridge.app" into dist/ and signs it.
#
# By default it's signed ad hoc. To sign with your own certificate (so macOS keeps the
# Accessibility permission across rebuilds), set SIGN_IDENTITY, and optionally BUNDLE_ID. Both
# can go in a `local.env` file next to this script, which git ignores:
#   SIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
#   BUNDLE_ID="com.example.Keybridge"
set -euo pipefail
cd "$(dirname "$0")"
[[ -f local.env ]] && source local.env

APP="dist/Keybridge.app"
IDENTITY="${SIGN_IDENTITY:--}"
BUNDLE_ID="${BUNDLE_ID:-app.keybridge.Keybridge}"
VERSION="${VERSION:-1.1.1}"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Keybridge"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Keybridge"
# The Windows companion (built by Windows/build-windows.sh), served to the PC by Crossover's setup page.
if [[ -f dist/KeyBridge-Control-PC.exe ]]; then cp dist/KeyBridge-Control-PC.exe "$APP/Contents/Resources/"; fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>Keybridge</string>
    <key>CFBundleDisplayName</key><string>Keybridge</string>
    <key>CFBundleExecutable</key><string>Keybridge</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>Crossover connects to Keybridge on your PC so this Mac's keyboard and mouse can control it.</string>
</dict>
</plist>
PLIST

if [[ "$IDENTITY" == - ]]; then
    codesign --force --sign - "$APP"
else
    codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $PWD/$APP"
