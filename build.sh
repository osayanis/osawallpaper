#!/bin/bash
# Build + empaquetage .app + signature.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
echo "▶︎ swift build ($CONFIG)…"
swift build -c "$CONFIG"
BIN=".build/$CONFIG/OsaWallpaper"

APP="OsaWallpaper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OsaWallpaper"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>OsaWallpaper</string>
  <key>CFBundleDisplayName</key><string>OsaWallpaper</string>
  <key>CFBundleIdentifier</key><string>com.osalabs.osawallpaper</string>
  <key>CFBundleExecutable</key><string>OsaWallpaper</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.19</string>
  <key>CFBundleVersion</key><string>21</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>OsaWallpaper lit et pilote Music ou Spotify pour afficher le morceau en cours sur ton fond d'écran.</string>
  <key>NSHumanReadableCopyright</key><string>OsaLabs</string>
</dict>
</plist>
PLIST

# Certificat « Apple Development » du trousseau s'il existe (les permissions
# macOS restent accordées d'un build à l'autre), sinon signature ad-hoc.
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')}"
codesign --force --deep --sign "${SIGN_ID:--}" "$APP" 2>/dev/null || true
echo "✅ $APP prêt."
