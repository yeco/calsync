#!/bin/sh
# Builds and signs CalSync.app. Signing by the local cert's SHA-1 keeps the identity (and calendar permission) stable across rebuilds.
set -e
cd "$(dirname "$0")"
HASH=$(cat .signing-hash 2>/dev/null || echo -)  # "-" = ad-hoc
APP=build/CalSync.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/menubar.png "$APP/Contents/Resources/menubar.png"
# App icon: build the .icns from the 512px PNG (sips resizes, iconutil packs).
SET=$(mktemp -d)/AppIcon.iconset && mkdir -p "$SET"
for s in 16 32 128 256 512; do sips -z $s $s Resources/icon.png --out "$SET/icon_${s}x${s}.png" >/dev/null; done
for s in 16 32 128 256; do sips -z $((s * 2)) $((s * 2)) Resources/icon.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null; done
iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 Sources/*.swift -o "$APP/Contents/MacOS/CalSync"
codesign -s "$HASH" -f --identifier me.yeco.CalSync "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated
