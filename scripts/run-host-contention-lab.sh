#!/bin/zsh
set -euo pipefail

# Host-side #19/#28 sampler. It does not launch or close browser tabs, media,
# builds, or terminals; hold the requested workload yourself and pass its
# label. The only optional process it starts is the installed headless host.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_PATH="$HOME/Applications/TabletBridge.app"
SCENARIO="manual"
DURATION=60
OUTPUT_DIR="$ROOT_DIR/runs/host-$(date +%Y%m%d-%H%M%S)"
HOST_PID="${SIDESCREEN_PID:-}"
LAUNCH_HEADLESS=0

while (( $# > 0 )); do
  case "$1" in
    --scenario) SCENARIO="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --pid) HOST_PID="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --launch-headless) LAUNCH_HEADLESS=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--scenario W0-W5] [--duration SECONDS] [--pid PID] [--output-dir DIR] [--launch-headless]"
      exit 0
      ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if ! [[ "$DURATION" =~ ^[1-9][0-9]*$ ]]; then
  echo "--duration must be a positive integer" >&2
  exit 2
fi

started_pid=""
cleanup() {
  if [[ -n "$started_pid" ]] && kill -0 "$started_pid" 2>/dev/null; then
    kill "$started_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

if [[ -z "$HOST_PID" ]] && (( LAUNCH_HEADLESS )); then
  if [[ ! -x "$APP_PATH/Contents/MacOS/TabletBridge" ]]; then
    echo "Installed executable not found: $APP_PATH/Contents/MacOS/TabletBridge" >&2
    exit 3
  fi
  "$APP_PATH/Contents/MacOS/TabletBridge" --headless >/tmp/tabletbridge-host-lab.stdout 2>/tmp/tabletbridge-host-lab.stderr &
  started_pid=$!
  HOST_PID="$started_pid"
  sleep 1
fi

if [[ -z "$HOST_PID" ]]; then
  for name in TabletBridge "Tablet Bridge" SideScreenHost; do
    HOST_PID="$(pgrep -x "$name" 2>/dev/null | head -n 1 || true)"
    [[ -n "$HOST_PID" ]] && break
  done
fi
if [[ -z "$HOST_PID" ]] || ! kill -0 "$HOST_PID" 2>/dev/null; then
  echo "Could not identify Tablet Bridge. Set --pid or use --launch-headless." >&2
  exit 4
fi

host_command="$(ps -p "$HOST_PID" -o command= | sed 's/^[[:space:]]*//')"
if [[ "$host_command" != *"TabletBridge"* ]]; then
  echo "PID $HOST_PID is not a Tablet Bridge executable: $host_command" >&2
  exit 5
fi
WINDOWSERVER_PID="$(pgrep -x WindowServer 2>/dev/null | head -n 1 || true)"
if [[ -z "$WINDOWSERVER_PID" ]]; then
  echo "Could not identify WindowServer." >&2
  exit 6
fi
SIDESCREEN_LOG="/tmp/tabletbridge.log"
log_start_bytes=0
if [[ -f "$SIDESCREEN_LOG" ]]; then
  log_start_bytes="$(wc -c < "$SIDESCREEN_LOG" | tr -d ' ')"
fi

mkdir -p "$OUTPUT_DIR"
cd "$ROOT_DIR"
git_sha="$(git rev-parse HEAD)"
macos_version="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
hardware="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Chip:/{print $2}')"
[[ -n "$hardware" ]] || hardware="unknown"
app_identity="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1 || true)"
cdhash="$(printf '%s\n' "$app_identity" | awk -F= '/^CDHash=/{print $2}')"
[[ -n "$cdhash" ]] || cdhash="unknown"

cat > "$OUTPUT_DIR/samples.csv" <<EOF
# source_sha=$git_sha
# installed_path=$APP_PATH
# cdhash=$cdhash
# host_pid=$HOST_PID
# windowserver_pid=$WINDOWSERVER_PID
# host_command=$host_command
# macos=$macos_version
# hardware=$hardware
# duration_s=$DURATION
# log_start_bytes=$log_start_bytes
timestamp,elapsed_s,scenario,sidescreen_cpu_pct,windowserver_cpu_pct,total_cpu_pct,memory_free_pct,swap_used_mb,thermal_warning
EOF

cpu_for_pid() {
  ps -p "$1" -o %cpu= 2>/dev/null | tr -d ' ' || true
}

free_memory_pct() {
  memory_pressure -Q 2>/dev/null | awk '/free percentage/{print $NF}' | tr -d '%' | head -n 1
}

swap_used_mb() {
  sysctl vm.swapusage 2>/dev/null | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p'
}

thermal_warning() {
  pmset -g therm 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | awk '{ if ($0 ~ /No thermal warning|No performance warning/) print "none"; else print "reported" }'
}

start_epoch="$(date +%s)"
for ((sample = 0; sample < DURATION; sample++)); do
  if ! kill -0 "$HOST_PID" 2>/dev/null; then
    echo "Tablet Bridge exited during sample $sample" >&2
    break
  fi
  now="$(date +%s)"
  host_cpu="$(cpu_for_pid "$HOST_PID")"; [[ -n "$host_cpu" ]] || host_cpu="nan"
  ws_cpu="$(cpu_for_pid "$WINDOWSERVER_PID")"; [[ -n "$ws_cpu" ]] || ws_cpu="nan"
  total_cpu="$(ps -A -o %cpu= 2>/dev/null | awk '{sum += $1} END {if (NR) printf "%.2f", sum; else print "nan"}')"
  free_pct="$(free_memory_pct)"; [[ -n "$free_pct" ]] || free_pct="nan"
  swap_mb="$(swap_used_mb)"; [[ -n "$swap_mb" ]] || swap_mb="nan"
  thermal="$(thermal_warning)"; [[ -n "$thermal" ]] || thermal="unknown"
  printf '%s,%d,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$((now - start_epoch))" "$SCENARIO" \
    "$host_cpu" "$ws_cpu" "$total_cpu" "$free_pct" "$swap_mb" "$thermal" >> "$OUTPUT_DIR/samples.csv"
  sleep 1
done

if [[ -f "$SIDESCREEN_LOG" ]]; then
  log_end_bytes="$(wc -c < "$SIDESCREEN_LOG" | tr -d ' ')"
  if (( log_end_bytes >= log_start_bytes )); then
    tail -c "+$((log_start_bytes + 1))" "$SIDESCREEN_LOG" > "$OUTPUT_DIR/sidescreen.log"
  else
    # The log was truncated or rotated while sampling; keep the available
    # post-rotation content rather than mixing it with an older run.
    cp "$SIDESCREEN_LOG" "$OUTPUT_DIR/sidescreen.log"
  fi
  {
    echo "SCStream frame geometry lines: $(rg -c 'SCStream frame geometry' "$OUTPUT_DIR/sidescreen.log" || true)"
    echo "Frame flow lines: $(rg -c 'Frame flow' "$OUTPUT_DIR/sidescreen.log" || true)"
    echo "Capture latency lines: $(rg -c 'Capture latency|capture->' "$OUTPUT_DIR/sidescreen.log" || true)"
    echo "Encoder configuration lines: $(rg -c 'VideoToolbox encoder configured' "$OUTPUT_DIR/sidescreen.log" || true)"
  } > "$OUTPUT_DIR/sidescreen-log-summary.txt"
fi

python3 "$SCRIPT_DIR/summarize-host-lab.py" "$OUTPUT_DIR/samples.csv" \
  --json "$OUTPUT_DIR/summary.json" \
  --markdown "$OUTPUT_DIR/summary.md" >/dev/null

cat > "$OUTPUT_DIR/run-metadata.txt" <<EOF
source_sha=$git_sha
installed_path=$APP_PATH
cdhash=$cdhash
host_pid=$HOST_PID
windowserver_pid=$WINDOWSERVER_PID
scenario=$SCENARIO
duration_s=$DURATION
macos=$macos_version
hardware=$hardware
log_start_bytes=$log_start_bytes
EOF

echo "Host contention lab run: $OUTPUT_DIR"
