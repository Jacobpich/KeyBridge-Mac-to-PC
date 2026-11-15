#!/bin/zsh
# Build and sign the Mac app. Set SIGN_IDENTITY to use your own signing certificate.
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/MX Control.app"
IDENTITY="${SIGN_IDENTITY:--}"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/MXControl"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MXControl"
# The Windows companion (built by Windows/build-windows.sh), served to the PC by Crossover's setup page.
if [[ -f dist/MXControlPC.exe ]]; then cp dist/MXControlPC.exe "$APP/Contents/Resources/"; fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>app.mxcontrol.Crossover</string>
    <key>CFBundleName</key><string>MX Control</string>
    <key>CFBundleDisplayName</key><string>MX Control</string>
    <key>CFBundleExecutable</key><string>MXControl</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>Crossover connects to MX Control on your PC so this Mac's keyboard and mouse can control it.</string>
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
