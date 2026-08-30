#!/bin/zsh
set -euo pipefail

# End-to-end digital visual-path lab.
#
# Native capture is fully automatable. Streamed capture assumes the user has
# already started the exact Tablet Bridge host profile and tapped Connect; this
# script never fakes a UI tap or changes production defaults. The host pattern
# injection keys are documented in this script and are intentionally opt-in
# for a run. Private evaluation receipts are not part of this repository.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE="dev.tabletbridge.app"
SERIAL="$(adb devices | awk 'NR > 1 && $2 == "device" { print $1; exit}')"
MODE="native"
PATTERN="static-ui"
WIDTH=2800
HEIGHT=1752
OUTPUT_DIR="$ROOT_DIR/runs/quality-$(date +%Y%m%d-%H%M%S)"

usage() {
  cat >&2 <<'EOF'
Usage: run-quality-lab.sh [options]

Options:
  --serial SERIAL          Android device serial (default: first ready device)
  --mode native|streamed|both
  --pattern NAME           static-ui, gradient, chroma, or motion-N
  --width PIXELS           default 2800
  --height PIXELS          default 1752
  --output-dir DIRECTORY

Native mode renders the exact corpus image in the internal Android lab
SurfaceView and captures it with PixelCopy. Streamed mode captures the active
Tablet Bridge SurfaceView with PixelCopy; the host must already be streaming the
same pattern.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --serial) SERIAL="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --pattern) PATTERN="$2"; shift 2 ;;
    --width) WIDTH="$2"; shift 2 ;;
    --height) HEIGHT="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

case "$MODE" in
  native|streamed|both) ;;
  *) echo "--mode must be native, streamed, or both" >&2; exit 2 ;;
esac

if [[ -z "$SERIAL" ]]; then
  echo "No ready Android device. Set --serial SERIAL." >&2
  exit 3
fi
if ! adb -s "$SERIAL" shell pm path "$PACKAGE" >/dev/null 2>&1; then
  echo "Package $PACKAGE is not installed on $SERIAL." >&2
  exit 4
fi

mkdir -p "$OUTPUT_DIR"
SOURCE="$OUTPUT_DIR/$PATTERN-reference.png"
QUALITY_LAB=(swift run -c release --package-path "$ROOT_DIR/MacHost/QualityLab" tabletbridge-quality-lab)
"${QUALITY_LAB[@]}" generate --pattern "$PATTERN" --width "$WIDTH" --height "$HEIGHT" --output "$SOURCE"

DEVICE_INPUT="/sdcard/Android/data/$PACKAGE/files/lab/input.png"
adb -s "$SERIAL" shell mkdir -p "/sdcard/Android/data/$PACKAGE/files/lab"
adb -s "$SERIAL" push "$SOURCE" "$DEVICE_INPUT" >/dev/null
adb -s "$SERIAL" shell run-as "$PACKAGE" mkdir -p files/lab
adb -s "$SERIAL" shell run-as "$PACKAGE" rm -f files/lab/native.png files/lab/streamed.png

pull_private() {
  local name="$1"
  local destination="$2"
  local relative="files/lab/$name"
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

broadcast_lab() {
  local op="$1"
  shift
  adb -s "$SERIAL" shell am broadcast \
    -a dev.tabletbridge.app.LAB_CMD \
    --es op "$op" "$@" >/dev/null
}

if [[ "$MODE" == native || "$MODE" == both ]]; then
  adb -s "$SERIAL" shell am force-stop "$PACKAGE"
  adb -s "$SERIAL" shell am start -n "$PACKAGE/.MainActivity" >/dev/null
  sleep 1
  broadcast_lab native_capture \
    --es source_path "$DEVICE_INPUT" \
    --es output_name native.png
  pull_private native.png "$OUTPUT_DIR/native.png"
  "${QUALITY_LAB[@]}" analyze \
    --reference "$SOURCE" \
    --output "$OUTPUT_DIR/native.png" \
    --json "$OUTPUT_DIR/native-metrics.json" \
    --markdown "$OUTPUT_DIR/native-report.md"
fi

if [[ "$MODE" == streamed || "$MODE" == both ]]; then
  echo "Waiting for an active Tablet Bridge stream; streamed PixelCopy will fail if the SurfaceView is idle." >&2
  broadcast_lab surface_capture \
    --es output_name streamed.png \
    --ei expected_width "$WIDTH" \
    --ei expected_height "$HEIGHT"
  pull_private streamed.png "$OUTPUT_DIR/streamed.png"
  "${QUALITY_LAB[@]}" analyze \
    --reference "$SOURCE" \
    --output "$OUTPUT_DIR/streamed.png" \
    --json "$OUTPUT_DIR/streamed-metrics.json" \
    --markdown "$OUTPUT_DIR/streamed-report.md"
fi

git_sha="$(git -C "$ROOT_DIR" rev-parse HEAD)"
device_model="$(adb -s "$SERIAL" shell getprop ro.product.model | tr -d '\r')"
device_release="$(adb -s "$SERIAL" shell getprop ro.build.version.release | tr -d '\r')"
cat > "$OUTPUT_DIR/run-metadata.txt" <<EOF
source_sha=$git_sha
package=$PACKAGE
serial=$SERIAL
model=$device_model
android_release=$device_release
pattern=$PATTERN
dimensions=${WIDTH}x${HEIGHT}
mode=$MODE
source=$SOURCE
EOF

echo "Quality lab run: $OUTPUT_DIR"
