#!/usr/bin/env bash
# Capture App Store / marketing screenshots from the UI-mock screens on a
# 6.9" iPhone Pro Max simulator with a clean 9:41 status bar.
#
# Usage: Scripts/screenshots.sh
# Output: docs/screenshots/*.png
set -euo pipefail

cd "$(dirname "$0")/.."
BUNDLE="${AIRLIFT_BUNDLE_ID:-com.santekotturi.airlift}"
OUT="docs/screenshots"
mkdir -p "$OUT"

# Pick a 6.9" Pro Max simulator (App Store's required size).
DEV=$(xcrun simctl list devices available | grep -E "iPhone .* Pro Max" | head -1 | grep -oE '\([0-9A-F-]{36}\)' | tr -d '()')
if [ -z "$DEV" ]; then
  echo "No iPhone Pro Max simulator found. Create one in Xcode > Settings > Platforms." >&2
  exit 1
fi
echo "Using simulator: $DEV"

# Build the app for the simulator if we can't find a fresh product.
APP=$(find ~/Library/Developer/Xcode/DerivedData -path "*Build/Products/Debug-iphonesimulator/Airlift.app" -maxdepth 6 2>/dev/null | head -1)
if [ -z "$APP" ]; then
  xcodegen generate
  xcodebuild build -project Airlift.xcodeproj -scheme Airlift \
    -destination "platform=iOS Simulator,id=$DEV" >/dev/null
  APP=$(find ~/Library/Developer/Xcode/DerivedData -path "*Build/Products/Debug-iphonesimulator/Airlift.app" -maxdepth 6 | head -1)
fi

xcrun simctl boot "$DEV" 2>/dev/null || true
open -a Simulator
sleep 3
xcrun simctl install "$DEV" "$APP"
# Clean, consistent status bar for every shot.
xcrun simctl status_bar "$DEV" override \
  --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiMode active --wifiBars 3 \
  --operatorName "" 2>/dev/null || true

shoot() { # <screen> <output-name>
  xcrun simctl terminate "$DEV" "$BUNDLE" 2>/dev/null || true
  xcrun simctl launch "$DEV" "$BUNDLE" -AirliftUIMock 1 -AirliftUIMockScreen "$1" >/dev/null
  sleep 4
  xcrun simctl io "$DEV" screenshot "$OUT/$2.png" >/dev/null
  echo "  $OUT/$2.png"
}

echo "Capturing:"
shoot onboarding 1-welcome
shoot home       2-home
shoot session    3-sleep
shoot metric     4-heart-rate
shoot calendar   5-calendar

echo "Done. Review $OUT/ and pick the best for App Store Connect (6.9\")."
