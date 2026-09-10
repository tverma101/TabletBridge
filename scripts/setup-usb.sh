#!/bin/bash
set -euo pipefail

BUNDLE_ID="dev.tabletbridge.host"
DEFAULT_PORT=54321

read_int_default() {
    local key="$1"
    local fallback="$2"
    local value
    value="$(defaults read "$BUNDLE_ID" "$key" 2>/dev/null || true)"
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value > 0 && value <= 65535 )); then
        printf '%s' "$value"
    else
        printf '%s' "$fallback"
    fi
}

PORT="${TABLETBRIDGE_PORT:-$(read_int_default SideScreen_port "$DEFAULT_PORT")}"
CONTROL_DEFAULT=$((PORT + 1))
CONTROL_PORT="${TABLETBRIDGE_CONTROL_PORT:-$(read_int_default SideScreen_controlPort "$CONTROL_DEFAULT")}"

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
    echo "❌ Invalid Tablet Bridge port: $PORT"
    exit 1
fi
if ! [[ "$CONTROL_PORT" =~ ^[0-9]+$ ]] || (( CONTROL_PORT < 1 || CONTROL_PORT > 65535 )); then
    echo "❌ Invalid Tablet Bridge control port: $CONTROL_PORT"
    exit 1
fi

echo "🔧 Setting up USB forwarding: video=$PORT control=$CONTROL_PORT"

# One device query is enough. Do not clear every reverse mapping on the device:
# other development tools may own unrelated adb reverse entries.
DEVICE_OUTPUT="$(adb devices)"
if ! grep -q $'\tdevice$' <<<"$DEVICE_OUTPUT"; then
    echo "❌ No Android device found via ADB"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Connect device via USB cable"
    echo "  2. Enable Developer Options on device"
    echo "  3. Enable USB Debugging in Developer Options"
    echo "  4. Accept the USB debugging prompt on device"
    exit 1
fi

echo "  ✓ Device connected"

# adb reverse replaces/refreshes the mapping directly; no remove/sleep cycle is
# required. Keep video and low-latency control on separate full-duplex sockets.
adb reverse "tcp:$PORT" "tcp:$PORT"
adb reverse "tcp:$CONTROL_PORT" "tcp:$CONTROL_PORT"

# Query the reverse table once and validate both mappings from the same snapshot.
REVERSE_LIST="$(adb reverse --list)"
if grep -q "tcp:$PORT tcp:$PORT" <<<"$REVERSE_LIST" \
    && grep -q "tcp:$CONTROL_PORT tcp:$CONTROL_PORT" <<<"$REVERSE_LIST"; then
    echo "  ✓ Video:   tcp:$PORT -> tcp:$PORT"
    echo "  ✓ Control: tcp:$CONTROL_PORT -> tcp:$CONTROL_PORT"
    echo ""
    echo "✅ USB port forwarding active"
else
    echo "❌ Port forwarding verification failed"
    echo "$REVERSE_LIST"
    exit 1
fi
