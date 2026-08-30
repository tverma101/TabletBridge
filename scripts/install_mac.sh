#!/bin/bash
set -euo pipefail

# Install exactly one user-facing host bundle. macOS Screen Recording approval
# is tied to the app's signing identity, so launching a second copy (for
# example an experimental bundle) can make an existing grant appear lost.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
USER_HOME="${HOME:?HOME is not set}"
SOURCE_APP="$ROOT_DIR/TabletBridge.app"
INSTALL_ROOT="${TABLETBRIDGE_INSTALL_ROOT:-${SIDESCREEN_INSTALL_ROOT:-$USER_HOME/Applications}}"
TARGET_APP="${TABLETBRIDGE_INSTALL_APP:-${SIDESCREEN_INSTALL_APP:-$INSTALL_ROOT/TabletBridge.app}}"
LAUNCH=false

if [ "${1:-}" = "--launch" ]; then
    LAUNCH=true
elif [ "${1:-}" != "" ]; then
    echo "Usage: $0 [--launch]" >&2
    exit 2
fi

if [ ! -d "$SOURCE_APP" ]; then
    echo "Missing current build: $SOURCE_APP" >&2
    echo "Run ./scripts/build_mac.sh first." >&2
    exit 1
fi

mkdir -p "$INSTALL_ROOT"

PREVIOUS_IDENTITY=""
PREVIOUS_DR=""
if [ -d "$TARGET_APP" ]; then
    PREVIOUS_IDENTITY="$(codesign -dvvv --verbose=4 "$TARGET_APP" 2>&1 | awk -F= '/^Authority=/{print $2; exit}' || true)"
    PREVIOUS_DR="$(codesign -d -r- "$TARGET_APP" 2>&1 | tail -1 || true)"
fi

# Stop only a process whose executable is inside the exact target bundle.
for pid in $(pgrep -f "$TARGET_APP/Contents/MacOS/TabletBridge" || true); do
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
        kill -TERM "$pid" 2>/dev/null || true
    fi
done

TEMP_ROOT="$(mktemp -d -t tabletbridge-install)"
cleanup() {
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

ditto --rsrc --extattr --qtn "$SOURCE_APP" "$TEMP_ROOT/TabletBridge.app"
"$SCRIPT_DIR/sign_mac_app.sh" "$TEMP_ROOT/TabletBridge.app"

if [ -e "$TARGET_APP" ]; then
    BACKUP_APP="$TARGET_APP.previous.$(date +%Y%m%d-%H%M%S)"
    mv "$TARGET_APP" "$BACKUP_APP"
    echo "Previous bundle preserved at: $BACKUP_APP"
fi
mv "$TEMP_ROOT/TabletBridge.app" "$TARGET_APP"

codesign --verify --deep --strict --verbose=2 "$TARGET_APP"
echo "Installed current host: $TARGET_APP"
CURRENT_CDHASH="$(codesign -dvvv --verbose=4 "$TARGET_APP" 2>&1 | awk -F= '/^CDHash=/{print $2}' || true)"
CURRENT_IDENTITY="$(codesign -dvvv --verbose=4 "$TARGET_APP" 2>&1 | awk -F= '/^Authority=/{print $2; exit}' || true)"
CURRENT_TEAM="$(codesign -dvvv --verbose=4 "$TARGET_APP" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}' || true)"
CURRENT_DR="$(codesign -d -r- "$TARGET_APP" 2>&1 | tail -1 || true)"
echo "Current CDHash: ${CURRENT_CDHASH:-unknown}"
echo "Current signing identity: ${CURRENT_IDENTITY:-unknown}"
echo "Current TeamIdentifier: ${CURRENT_TEAM:-unknown}"
if [ -n "$PREVIOUS_IDENTITY" ] && [ -n "$CURRENT_IDENTITY" ] && [ "$PREVIOUS_IDENTITY" != "$CURRENT_IDENTITY" ]; then
    echo "Signing identity changed: $PREVIOUS_IDENTITY -> $CURRENT_IDENTITY"
    echo "A one-time Screen Recording rebind may be required for the new stable identity."
fi
if [ -n "$PREVIOUS_DR" ] && [ -n "$CURRENT_DR" ] && [ "$PREVIOUS_DR" != "$CURRENT_DR" ]; then
    echo "Designated requirement changed; re-enable this exact bundle once in Screen & System Audio Recording."
fi
echo "Stable Apple Development signing is required for Screen Recording continuity."
echo "Screen Recording preflight is advisory; this host will attempt capture and report the actual result."
echo "Use this exact bundle for the grant; do not launch a legacy copy."
printf 'Current designated requirement: %s\n' "${CURRENT_DR:-unknown}"

if $LAUNCH; then
    open -n "$TARGET_APP"
fi
