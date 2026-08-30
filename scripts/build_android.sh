#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "🔨 Building Android Client..."
cd "$ROOT_DIR/AndroidClient"

# Prefer an explicitly supplied JDK, then Android Studio's bundled JDK, then
# the macOS-managed Java 21 installation used by this project.
if [ -z "${JAVA_HOME:-}" ] || [ ! -x "$JAVA_HOME/bin/java" ]; then
    ANDROID_STUDIO_JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
    if [ -x "$ANDROID_STUDIO_JAVA_HOME/bin/java" ]; then
        export JAVA_HOME="$ANDROID_STUDIO_JAVA_HOME"
    elif [ -x "/usr/libexec/java_home" ]; then
        JAVA_HOME="$(/usr/libexec/java_home -v 21 2>/dev/null || true)"
        export JAVA_HOME
    fi
fi

if [ -z "${JAVA_HOME:-}" ] || [ ! -x "$JAVA_HOME/bin/java" ]; then
    echo "❌ Java 21 not found"
    echo "   Install Android Studio, install a Java 21 JDK, or set JAVA_HOME manually"
    exit 1
fi

./gradlew assembleDebug

echo ""
echo "✅ Build successful!"
echo ""
echo "📦 APK: $ROOT_DIR/AndroidClient/app/build/outputs/apk/debug/app-debug.apk"
echo ""
echo "To install on device:"
echo "  adb install -r $ROOT_DIR/AndroidClient/app/build/outputs/apk/debug/app-debug.apk"
echo ""
echo "Or run: ./scripts/install_android.sh"
