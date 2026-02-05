#!/bin/bash
set -e

DEBUG=false
WATCH=false

# Parse arguments
for arg in "$@"; do
    case $arg in
        --debug|-d)
            DEBUG=true
            ;;
        --watch|-w)
            WATCH=true
            ;;
    esac
done

build_app() {
    echo "Building pulse..."
    xcodebuild -scheme pulse -configuration Debug build 2>&1 | grep -E "(error:|warning:|BUILD)" | tail -10
    return ${PIPESTATUS[0]}
}

get_app_path() {
    # Find most recently modified pulse.app
    find ~/Library/Developer/Xcode/DerivedData/pulse-*/Build/Products/Debug/pulse.app -maxdepth 0 -type d 2>/dev/null | head -1
}

kill_app() {
    pkill -x pulse 2>/dev/null || true
}

launch_app() {
    local app_path="$1"
    if $DEBUG; then
        echo "Launching pulse in debug mode..."
        echo "---"
        "$app_path/Contents/MacOS/pulse" &
        APP_PID=$!
    else
        open "$app_path"
    fi
}

# Initial build
build_app

APP_PATH=$(get_app_path)
if [[ -z "$APP_PATH" ]]; then
    echo "Error: Could not find built app"
    exit 1
fi

if $WATCH; then
    # Check if fswatch is installed
    if ! command -v fswatch &> /dev/null; then
        echo "Error: fswatch is required for --watch mode"
        echo "Install it with: brew install fswatch"
        exit 1
    fi

    echo "Starting pulse with file watching..."
    echo "Watching for changes in pulse/ directory"
    echo "Press Ctrl+C to stop"
    echo "---"

    # Launch initial app
    launch_app "$APP_PATH"

    # Watch for changes and rebuild
    fswatch -o -e ".*" -i "\\.swift$" -i "\\.xib$" -i "\\.storyboard$" -i "\\.xcassets" pulse/ | while read -r; do
        echo ""
        echo "Change detected, rebuilding..."
        kill_app
        sleep 0.5

        if build_app; then
            APP_PATH=$(get_app_path)
            if [[ -n "$APP_PATH" ]]; then
                launch_app "$APP_PATH"
                echo "Restarted."
            fi
        else
            echo "Build failed. Waiting for next change..."
        fi
    done
else
    # Normal single run
    if $DEBUG; then
        echo "Launching pulse in debug mode (Ctrl+C to quit)..."
        echo "---"
        "$APP_PATH/Contents/MacOS/pulse"
    else
        echo "Launching pulse..."
        open "$APP_PATH"
        echo "Done. Check your menu bar for the pulse icon."
        echo "Tip: Use './run.sh --debug' to see console output"
        echo "Tip: Use './run.sh --watch' to auto-restart on changes"
    fi
fi
