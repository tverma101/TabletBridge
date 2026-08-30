#!/bin/zsh
set -euo pipefail

# Collect raw Android render timing for one active Tablet Bridge session. The
# script deliberately does not tap Connect or switch USB/wireless: run the
# same command once per transport after the user has established that mode.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE="dev.tabletbridge.app"
SERIAL="$(adb devices | awk 'NR > 1 && $2 == "device" { print $1; exit}')"
DURATION=30
TARGET_FPS=60
OUTPUT_DIR="$ROOT_DIR/runs/smoothness-$(date +%Y%m%d-%H%M%S)"
PERFETTO=0

usage() {
  cat >&2 <<'EOF'
Usage: run-smoothness-lab.sh [options]

Options:
  --serial SERIAL
  --duration SECONDS       default 30
  --target-fps FPS         default 60
  --output-dir DIRECTORY
  --perfetto               request a companion SurfaceFlinger trace

Start the intended Tablet Bridge session first. The runner records the Android
frame trace while that session is active and emits CSV, JSON, Markdown,
logcat, and exact runtime metadata.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --serial) SERIAL="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --target-fps) TARGET_FPS="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --perfetto) PERFETTO=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$SERIAL" ]]; then
  echo "No ready Android device. Set --serial SERIAL." >&2
  exit 3
fi
if ! [[ "$DURATION" =~ ^[1-9][0-9]*$ ]]; then
  echo "--duration must be a positive integer" >&2
  exit 2
fi
if ! adb -s "$SERIAL" shell pm path "$PACKAGE" >/dev/null 2>&1; then
  echo "Package $PACKAGE is not installed on $SERIAL." >&2
  exit 4
fi

mkdir -p "$OUTPUT_DIR"
TRACE_NAME="frame-trace.csv"
adb -s "$SERIAL" shell am broadcast \
  -a dev.tabletbridge.app.LAB_CMD \
  --es op trace_start \
  --es output_name "$TRACE_NAME" >/dev/null

perfetto_device="/data/local/tmp/tabletbridge-${RANDOM}.perfetto-trace"
perfetto_error="$OUTPUT_DIR/perfetto.stderr"
perfetto_status="not_requested"
perfetto_exit="not_run"
if (( PERFETTO )); then
  # `perfetto` may be unavailable or permission-limited on a retail build;
  # keep that failure visible in the run metadata rather than treating it as
  # proof that no SurfaceFlinger trace exists.
  : > "$perfetto_error"
  adb -s "$SERIAL" shell perfetto -o "$perfetto_device" -t "${DURATION}s" \
    sched freq idle am wm gfx view binder_driver hal >/dev/null 2>"$perfetto_error" &
  perfetto_pid=$!
  perfetto_status="pending"
else
  perfetto_pid=""
fi

sleep "$DURATION"

adb -s "$SERIAL" shell am broadcast \
  -a dev.tabletbridge.app.LAB_CMD \
  --es op trace_stop >/dev/null

pull_private() {
  local relative="$1"
  local destination="$2"
  local previous_size=0
  for _ in {1..80}; do
    local size="$(adb -s "$SERIAL" shell run-as "$PACKAGE" ls -l "$relative" 2>/dev/null | awk 'NF >= 5 {print $5}' | tr -d '\r')"
    if [[ -n "$size" ]] && (( size > 0 )) && [[ "$size" == "$previous_size" ]]; then
      adb -s "$SERIAL" exec-out run-as "$PACKAGE" cat "$relative" > "$destination"
      return 0
    fi
    previous_size="$size"
    sleep 0.25
  done
  echo "Timed out waiting for $relative" >&2
  return 1
}

pull_private "files/lab/$TRACE_NAME" "$OUTPUT_DIR/$TRACE_NAME"
adb -s "$SERIAL" exec-out run-as "$PACKAGE" cat files/diag.log > "$OUTPUT_DIR/diag.log" 2>/dev/null || true
adb -s "$SERIAL" logcat -d -v threadtime -s VD:V MA:V LAB:V DiagLog:V '*:S' > "$OUTPUT_DIR/logcat.txt" 2>/dev/null || true

if (( PERFETTO )); then
  if [[ -n "$perfetto_pid" ]]; then
    if wait "$perfetto_pid"; then
      perfetto_exit=0
    else
      perfetto_exit=$?
    fi
  fi
  perfetto_trace="$OUTPUT_DIR/$(basename "$perfetto_device")"
  if adb -s "$SERIAL" pull "$perfetto_device" "$OUTPUT_DIR/" >/dev/null 2>>"$perfetto_error"; then
    perfetto_status="collected"
  else
    perfetto_status="unavailable"
    rm -f "$perfetto_trace"
  fi
  adb -s "$SERIAL" shell rm -f "$perfetto_device" >/dev/null 2>&1 || true
fi

python3 "$SCRIPT_DIR/analyze-frame-trace.py" "$OUTPUT_DIR/$TRACE_NAME" \
  --target-fps "$TARGET_FPS" \
  --json "$OUTPUT_DIR/summary.json" \
  --markdown "$OUTPUT_DIR/summary.md"

git_sha="$(git -C "$ROOT_DIR" rev-parse HEAD)"
device_model="$(adb -s "$SERIAL" shell getprop ro.product.model | tr -d '\r')"
device_release="$(adb -s "$SERIAL" shell getprop ro.build.version.release | tr -d '\r')"
mac_app="$HOME/Applications/TabletBridge.app"
mac_cdhash="unknown"
if [[ -e "$mac_app" ]]; then
  mac_identity="$(codesign -dv --verbose=4 "$mac_app" 2>&1 || true)"
  mac_cdhash="$(printf '%s\n' "$mac_identity" | awk -F= '/^CDHash=/{print $2}')"
  [[ -n "$mac_cdhash" ]] || mac_cdhash="unknown"
fi
cat > "$OUTPUT_DIR/run-metadata.txt" <<EOF
source_sha=$git_sha
package=$PACKAGE
serial=$SERIAL
model=$device_model
android_release=$device_release
target_fps=$TARGET_FPS
duration_s=$DURATION
perfetto_requested=$PERFETTO
perfetto_status=$perfetto_status
perfetto_exit=$perfetto_exit
perfetto_error=$([[ "$PERFETTO" == 1 ]] && printf '%s' "$perfetto_error" || printf '%s' '')
mac_installed_path=$mac_app
mac_cdhash=$mac_cdhash
EOF

echo "Smoothness lab run: $OUTPUT_DIR"
