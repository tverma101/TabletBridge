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

# Setup USB if device connected
if adb devices 2>/dev/null | grep -q "device$"; then
    echo "📱 Android device detected, setting up USB..."
    adb reverse --remove tcp:8888 2>/dev/null || true
    adb reverse tcp:8888 tcp:8888
    echo "  ✓ Port forwarding ready"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Open 'Tablet Bridge' on Android and tap Connect"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
