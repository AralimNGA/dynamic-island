#!/bin/bash
# Baut DynamicIsland.app und installiert sie nach ~/Applications.
# Aufruf:  ./build.sh         (bauen + installieren)
#          ./build.sh run     (bauen + installieren + starten)
set -euo pipefail

APP_NAME="DynamicIsland"
DISPLAY_NAME="Dynamic Island"
BUNDLE_ID="com.aralim.dynamicisland"
INSTALL_DIR="$HOME/Applications"
APP="$INSTALL_DIR/$APP_NAME.app"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "▶︎ Kompiliere (release)…"
cd "$HERE"
swift build -c release
BIN="$HERE/.build/release/$APP_NAME"

# Adapter VOR dem Löschen der installierten App bauen – schlägt etwas fehl,
# bleibt die bisherige App intakt.
echo "▶︎ Baue MediaRemote-Adapter (systemweites Now Playing)…"
STAGE="$(mktemp -d -t island_mr)"
trap 'rm -rf "$STAGE"' EXIT
"$HERE/Vendor/build_mediaremote.sh" "$STAGE"

echo "▶︎ Schnüre App-Bundle: $APP"
# Laufende Instanz beenden, damit die Binary ersetzt werden kann.
pkill -x "$APP_NAME" 2>/dev/null || true
pkill -f "DynamicIsland.app/Contents/Resources/mediaremote-adapter.pl" 2>/dev/null || true
sleep 0.3
mkdir -p "$INSTALL_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Dynamic Island liest Titelinfos aus Spotify und Apple Music und steuert die Wiedergabe.</string>
  <key>NSCalendarsUsageDescription</key><string>Dynamic Island zeigt deinen nächsten Termin an.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Dynamic Island zeigt deinen nächsten Termin an.</string>
  <key>NSCameraUsageDescription</key><string>Die Spiegel-Funktion zeigt ein Live-Kamerabild in der Island.</string>
  <key>NSMicrophoneUsageDescription</key><string>Die Aufnahme-Funktion nimmt Audio über das Mikrofon auf.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Dynamic Island liest den Akkustand deiner AirPods in der Nähe – auch wenn sie mit dem iPhone verbunden sind.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Dynamic Island liest den Akkustand deines iPhones und iPads über das WLAN.</string>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

mkdir -p "$APP/Contents/Frameworks"
ditto "$STAGE/MediaRemoteAdapter.framework" "$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
cp "$STAGE/mediaremote-adapter.pl" "$APP/Contents/Resources/"

ENT="$(mktemp -t island_ent).plist"
cat > "$ENT" <<ENTPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.automation.apple-events</key><true/>
  <key>com.apple.security.device.camera</key><true/>
  <key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
ENTPLIST

echo "▶︎ Signiere (ad-hoc)…"
codesign -s - --force --options runtime --entitlements "$ENT" "$APP"
rm -f "$ENT"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature" || true

echo "✓ Fertig: $APP"

if [ "${1:-}" = "run" ]; then
  echo "▶︎ Starte…"
  open "$APP"
fi
