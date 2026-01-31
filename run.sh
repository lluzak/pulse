#!/bin/bash
set -e

DEBUG=false
if [[ "$1" == "--debug" || "$1" == "-d" ]]; then
    DEBUG=true
fi

echo "Building pulse..."
xcodebuild -scheme pulse -configuration Debug build 2>&1 | grep -E "(error:|warning:|BUILD)" | tail -5

APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/pulse-*/Build/Products/Debug/pulse.app -maxdepth 0 2>/dev/null | head -1)

if [[ -z "$APP_PATH" ]]; then
    echo "Error: Could not find built app"
    exit 1
fi

if $DEBUG; then
    echo "Launching pulse in debug mode (Ctrl+C to quit)..."
    echo "---"
    "$APP_PATH/Contents/MacOS/pulse"
else
    echo "Launching pulse..."
    open "$APP_PATH"
    echo "Done. Check your menu bar for the pulse icon."
    echo "Tip: Use './run.sh --debug' to see console output"
fi
