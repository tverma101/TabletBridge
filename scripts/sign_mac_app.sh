#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/TabletBridge.app}"

if [ ! -d "$APP_PATH" ]; then
    echo "App bundle not found: $APP_PATH" >&2
    exit 1
fi

IDENTITY_REPORT="$(security find-identity -v -p codesigning 2>/dev/null || true)"
SIGNING_IDENTITY="${TABLETBRIDGE_CODESIGN_IDENTITY:-${SIDESCREEN_CODESIGN_IDENTITY:-}}"

if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY="$(printf '%s\n' "$IDENTITY_REPORT" \
        | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
        | head -1)"
fi

if [ -z "$SIGNING_IDENTITY" ]; then
    echo "No valid Apple Development signing identity is available." >&2
    echo "Open Xcode → Settings → Apple Accounts and create/select the Personal Team certificate." >&2
    echo "The build intentionally refuses ad-hoc signing because it breaks macOS TCC identity continuity." >&2
    exit 2
fi

if ! printf '%s\n' "$IDENTITY_REPORT" \
    | awk -v identity="$SIGNING_IDENTITY" 'index($0, "\"" identity "\"") { found = 1 } END { exit found ? 0 : 1 }'; then
    echo "Signing identity is not a valid Apple Development identity: $SIGNING_IDENTITY" >&2
    exit 2
fi

echo "Signing with: $SIGNING_IDENTITY"

codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp=none \
    --sign "$SIGNING_IDENTITY" \
    --entitlements "$ROOT_DIR/MacHost/SideScreen.entitlements" \
    "$APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dvvv "$APP_PATH" 2>&1 | rg '^(Identifier|Authority|TeamIdentifier|CDHash)=' || true
codesign -d -r- "$APP_PATH" 2>&1 | tail -4
