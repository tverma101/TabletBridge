#!/bin/zsh
set -euo pipefail

# Tablet Bridge adaptive-refresh benchmark sampler.
#
# Usage:
#   ./scripts/benchmark-adaptive-refresh.sh <scenario> [seconds] [output.csv]
#
# Examples:
#   ./scripts/benchmark-adaptive-refresh.sh static-terminal 30
#   SIDESCREEN_PID=1234 ./scripts/benchmark-adaptive-refresh.sh youtube-60 45 results/youtube-60.csv
#
# The script intentionally does not sudo or change system state. Run the exact
# same scenario against exp/quality-fork and fix/adaptive-refresh-governor.

scenario="${1:-manual}"
duration="${2:-30}"
output="${3:-adaptive-refresh-${scenario}-$(date +%Y%m%d-%H%M%S).csv}"

if ! [[ "$duration" =~ ^[0-9]+$ ]] || (( duration < 1 )); then
  echo "seconds must be a positive integer" >&2
  exit 2
fi

find_host_pid() {
  if [[ -n "${SIDESCREEN_PID:-}" ]]; then
    echo "$SIDESCREEN_PID"
    return
  fi

  # Bundle/process names have changed during experiments, so try the common
  # exact names first and then a conservative command-line match.
  local pid
  for name in TabletBridge "Tablet Bridge" SideScreenHost; do
    pid="$(pgrep -x "$name" 2>/dev/null | head -n 1 || true)"
    if [[ -n "$pid" ]]; then
      echo "$pid"
      return
    fi
  done

  pid="$(pgrep -f '/TabletBridge([^/]*)\.app/|/MacHost/.build/.*/TabletBridge' 2>/dev/null | head -n 1 || true)"
  echo "$pid"
}

host_pid="$(find_host_pid)"
windowserver_pid="$(pgrep -x WindowServer 2>/dev/null | head -n 1 || true)"

if [[ -z "$host_pid" ]]; then
  echo "Could not find Tablet Bridge. Set SIDESCREEN_PID=<pid> and retry." >&2
  exit 3
fi
if [[ -z "$windowserver_pid" ]]; then
  echo "Could not find WindowServer." >&2
  exit 4
fi
if ! kill -0 "$host_pid" 2>/dev/null; then
  echo "Tablet Bridge PID $host_pid is not running." >&2
  exit 5
fi

mkdir -p "${output:h}"

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
commit="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
os_version="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
hardware="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Chip:/{print $2; exit}')"
[[ -n "$hardware" ]] || hardware="unknown"

cat > "$output" <<EOF
# scenario=$scenario
# duration_s=$duration
# branch=$branch
# commit=$commit
# macos=$os_version
# hardware=$hardware
# sidescreen_pid=$host_pid
# windowserver_pid=$windowserver_pid
timestamp,elapsed_s,scenario,sidescreen_cpu_pct,windowserver_cpu_pct
EOF

cpu_for_pid() {
  ps -p "$1" -o %cpu= 2>/dev/null | tr -d ' ' || true
}

start_epoch="$(date +%s)"
for ((i = 0; i < duration; i++)); do
  if ! kill -0 "$host_pid" 2>/dev/null; then
    echo "Tablet Bridge exited during sample $i" >&2
    break
  fi

  now="$(date +%s)"
  host_cpu="$(cpu_for_pid "$host_pid")"
  ws_cpu="$(cpu_for_pid "$windowserver_pid")"
  [[ -n "$host_cpu" ]] || host_cpu="nan"
  [[ -n "$ws_cpu" ]] || ws_cpu="nan"

  printf '%s,%d,%s,%s,%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$((now - start_epoch))" \
    "$scenario" \
    "$host_cpu" \
    "$ws_cpu" >> "$output"

  sleep 1
done

awk -F, '
  BEGIN { host_n=0; ws_n=0; host_sum=0; ws_sum=0 }
  /^#/ || $1=="timestamp" { next }
  $4 != "nan" { host_sum += $4; host_n++ }
  $5 != "nan" { ws_sum += $5; ws_n++ }
  END {
    if (host_n) printf("Tablet Bridge mean CPU: %.2f%%\n", host_sum/host_n)
    if (ws_n) printf("WindowServer mean CPU: %.2f%%\n", ws_sum/ws_n)
  }
' "$output"

echo "CSV: $output"
echo "Compare this file with the same scenario/seconds on exp/quality-fork."
echo "Also capture Tablet Bridge logs containing 'Adaptive refresh:' for tier transitions."
