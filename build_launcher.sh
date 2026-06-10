#!/bin/bash
# Erstellt einen Doppelklick-Starter „Dynamic Island starten.app" auf dem Schreibtisch.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="$HOME/Desktop/Dynamic Island starten.app"

echo "▶︎ Icon zeichnen…"
swift "$HERE/makeicon.swift" /tmp/island_icon.png

echo "▶︎ Iconset bauen…"
ICONSET=/tmp/island.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" /tmp/island_icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" /tmp/island_icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o /tmp/island.icns

echo "▶︎ Launcher-App erstellen…"
APPLESCRIPT=/tmp/island_launcher.applescript
cat > "$APPLESCRIPT" <<'AS'
on run
	try
		set appPath to (POSIX path of (path to home folder)) & "Applications/DynamicIsland.app"
		do shell script "open " & quoted form of appPath
	on error errMsg
		display dialog "Dynamic Island konnte nicht gestartet werden." & return & errMsg buttons {"OK"} default button "OK" with icon caution
	end try
end run
AS
rm -rf "$LAUNCHER"
osacompile -o "$LAUNCHER" "$APPLESCRIPT"

echo "▶︎ Icon setzen…"
cp /tmp/island.icns "$LAUNCHER/Contents/Resources/applet.icns"
plutil -replace CFBundleName -string "Dynamic Island starten" "$LAUNCHER/Contents/Info.plist" >/dev/null 2>&1 || true

echo "▶︎ Signieren & registrieren…"
codesign -s - --force --deep "$LAUNCHER" >/dev/null 2>&1 || true
touch "$LAUNCHER"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$LAUNCHER" >/dev/null 2>&1 || true

echo "✓ Starter erstellt: $LAUNCHER"
