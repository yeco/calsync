#!/bin/sh
# Builds and signs CalSync.app. Signing by the local cert's SHA-1 keeps the identity (and calendar permission) stable across rebuilds.
set -e
cd "$(dirname "$0")"
HASH=$(cat .signing-hash 2>/dev/null || echo -)  # "-" = ad-hoc
APP=build/CalSync.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 Sources/*.swift -o "$APP/Contents/MacOS/CalSync"
codesign -s "$HASH" -f --identifier me.yeco.CalSync "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated
