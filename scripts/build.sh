#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/Pi Voice Assistant.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -swift-version 5 -O Sources/*.swift -o "$APP/Contents/MacOS/PiVoiceAssistant" -framework AppKit -framework AVFoundation -framework ApplicationServices
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp scripts/gigaam_recognize.py scripts/auto-session-title.ts "$APP/Contents/Resources/"
# Ad-hoc signing is not notarization; rebuilds can affect macOS permission recognition.
codesign --force --deep --sign - "$APP"
echo "Built $APP"
