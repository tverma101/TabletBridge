#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APK_PATH="$ROOT_DIR/AndroidClient/app/build/outputs/apk/debug/app-debug.apk"

echo "📱 Installing Android app..."

# Check if APK exists
if [ ! -f "$APK_PATH" ]; then
    echo "❌ APK not found. Building first..."
    "$SCRIPT_DIR/build_android.sh"
fi

# Check ADB connection
if ! adb devices | grep -q $'\tdevice$'; then
    echo "❌ No Android device found via ADB"
    echo "   Please connect your device via USB and enable USB debugging"
    exit 1
fi

# Install APK
adb install -r "$APK_PATH"

echo ""
echo "✅ App installed successfully!"
echo ""

# Use the single source of truth for the saved/default video + control ports.
"$SCRIPT_DIR/setup-usb.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Ready! Open 'Tablet Bridge' on your Android device"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
