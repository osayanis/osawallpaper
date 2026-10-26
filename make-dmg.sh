#!/bin/bash
# Fabrique OsaWallpaper.dmg : fenêtre d'installation façon Discord
# (logo de l'app + dossier Applications + flèche « glisse-moi dedans »).
set -euo pipefail
cd "$(dirname "$0")"

APP="OsaWallpaper.app"
DMG="OsaWallpaper.dmg"
VOL="OsaWallpaper"
BG="dmg-background.png"

[ -d "$APP" ] || { echo "❌ $APP introuvable — lance ./build.sh d'abord"; exit 1; }

echo "▶︎ préparation…"
rm -f "$DMG" rw.dmg
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
mkdir "$STAGE/.background"
cp "$BG" "$STAGE/.background/bg.png"
ln -s /Applications "$STAGE/Applications"

echo "▶︎ création de l'image lecture/écriture…"
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ \
    -format UDRW -ov rw.dmg >/dev/null

echo "▶︎ montage…"
DEV="$(hdiutil attach -readwrite -noverify -noautoopen rw.dmg | egrep '^/dev/' | sed 1q | awk '{print $1}')"
MNT="/Volumes/$VOL"
sleep 2

echo "▶︎ mise en page de la fenêtre…"
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {300, 140, 900, 540}
        set theOpts to the icon view options of container window
        set arrangement of theOpts to not arranged
        set icon size of theOpts to 120
        set background picture of theOpts to file ".background:bg.png"
        set position of item "$APP" of container window to {150, 185}
        set position of item "Applications" of container window to {450, 185}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

sync
echo "▶︎ finalisation (compression)…"
hdiutil detach "$DEV" >/dev/null || hdiutil detach "$DEV" -force >/dev/null
hdiutil convert rw.dmg -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f rw.dmg
rm -rf "$STAGE"

echo "✅ $DMG prêt ($(du -h "$DMG" | cut -f1))."
