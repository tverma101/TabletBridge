#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "🚀 Starting Tablet Bridge..."

# Stop only this checkout's generated bundle.
pkill -f "$ROOT_DIR/TabletBridge.app/Contents/MacOS/TabletBridge" 2>/dev/null || true
sleep 0.3

# Check if app bundle exists
if [ -d "$ROOT_DIR/TabletBridge.app" ]; then
    echo "  Opening TabletBridge.app..."
    open "$ROOT_DIR/TabletBridge.app"
elif [ -f "$ROOT_DIR/MacHost/.build/release/TabletBridge" ]; then
    echo "  Running release binary..."
    "$ROOT_DIR/MacHost/.build/release/TabletBridge" &
elif [ -f "$ROOT_DIR/MacHost/.build/debug/TabletBridge" ]; then
    echo "  Running debug binary..."
    "$ROOT_DIR/MacHost/.build/debug/TabletBridge" &
else
    echo "❌ No build found. Building now..."
    "$SCRIPT_DIR/build_mac.sh"
    echo ""
    echo "  Opening TabletBridge.app..."
    open "$ROOT_DIR/TabletBridge.app"
fi

echo ""
echo "✅ Mac app started!"
echo ""

# Setup both the video and low-latency control reverse mappings with the same
# saved ports the Mac app uses. setup-usb.sh performs one verification snapshot.
if adb devices 2>/dev/null | grep -q $'\tdevice$'; then
    echo "📱 Android device detected, setting up USB..."
    "$SCRIPT_DIR/setup-usb.sh"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Open 'Tablet Bridge' on Android and tap Connect"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
