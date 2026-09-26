#!/bin/bash
# Baut MediaRemoteAdapter.framework (arm64) aus dem Quellcode in Vendor/ und legt
# es samt Perl-Starter in <Zielordner>. Aufruf: Vendor/build_mediaremote.sh <Zielordner>
set -euo pipefail
HERE="$(cd "$(dirname "$0")/mediaremote-adapter" && pwd)"
OUT="${1:?Zielordner fehlt}"
FW="$OUT/MediaRemoteAdapter.framework"
rm -rf "$FW"
mkdir -p "$FW/Versions/A/Resources"
SRC=( "$HERE"/src/adapter/*.m "$HERE"/src/private/*.m "$HERE"/src/utility/*.m )
clang -arch arm64 -mmacosx-version-min=14.0 -dynamiclib -fobjc-arc -fvisibility=default -O2 -w \
  -I "$HERE/include" -I "$HERE/src" \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  -install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
  -o "$FW/Versions/A/MediaRemoteAdapter" "${SRC[@]}"
cat > "$FW/Versions/A/Resources/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.aralim.dynamicisland.MediaRemoteAdapter</string>
  <key>CFBundleName</key><string>MediaRemoteAdapter</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
</dict></plist>
PL
ln -s A "$FW/Versions/Current"
ln -s Versions/Current/MediaRemoteAdapter "$FW/MediaRemoteAdapter"
ln -s Versions/Current/Resources "$FW/Resources"
codesign --force --sign - "$FW" >/dev/null
cp "$HERE/bin/mediaremote-adapter.pl" "$OUT/mediaremote-adapter.pl"
