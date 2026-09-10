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

# EXPERIMENTAL: modern ADB can negotiate burst/delayed acknowledgements so a
# forwarded asocket can keep multiple payloads in flight instead of waiting for
# one A_OKAY after every A_WRTE. This changes the ADB *server* feature set, so it
# only takes effect when the server is started with ADB_BURST_MODE=1.
#
# Keep it opt-in until Tablet Bridge latency/frame-pacing is A/B measured on the
# actual tablet: AOSP's published win is USB file-transfer throughput, not an
# interactive-display latency guarantee.
#
# Usage:
#   TABLETBRIDGE_ADB_BURST=1 ./scripts/setup-usb.sh
if [[ "${TABLETBRIDGE_ADB_BURST:-0}" == "1" ]]; then
    echo "🧪 ADB Burst Mode requested — restarting adb server for this experiment"
    adb kill-server >/dev/null 2>&1 || true
    ADB_BURST_MODE=1 adb start-server >/dev/null

    SERVER_STATUS="$(adb server-status 2>/dev/null || true)"
    if grep -Eiq 'burst[_ -]?mode[^[:alnum:]]*(true|1|enabled)' <<<"$SERVER_STATUS"; then
        echo "  ✓ ADB server reports Burst Mode enabled"
    else
        echo "  ⚠ Could not verify Burst Mode; this platform-tools build may not expose/support it"
    fi
fi

# One device query is enough in the normal path. After an explicit ADB server
# restart for Burst Mode, allow USB enumeration a short bounded window to return.
DEVICE_OUTPUT=""
ATTEMPTS=1
if [[ "${TABLETBRIDGE_ADB_BURST:-0}" == "1" ]]; then
    ATTEMPTS=20
fi
for ((i = 1; i <= ATTEMPTS; i++)); do
    DEVICE_OUTPUT="$(adb devices)"
    if grep -q $'\tdevice$' <<<"$DEVICE_OUTPUT"; then
        break
    fi
    if (( i < ATTEMPTS )); then
        sleep 0.25
    fi
done

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
