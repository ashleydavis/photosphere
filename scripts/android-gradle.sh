#!/usr/bin/env bash
# Runs the Android app's Gradle with a JDK 17 and the Android SDK resolved, so native Gradle tasks
# (e.g. `bun run test:android:unit`) work without the caller exporting JAVA_HOME / ANDROID_HOME.
# AGP fails on the JDK 21 that Android Studio bundles, so a JDK 17 is required; this mirrors the
# ensure_jdk17 discovery the smoke-test harness uses.
#
# Usage: scripts/android-gradle.sh <gradle-task> [args...]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# True when the given path is a JDK 17 installation.
java_is_17() {
    [ -n "${1:-}" ] && [ -x "$1/bin/java" ] && "$1/bin/java" -version 2>&1 | grep -q 'version "17'
}

# Select a JDK 17: honor an already-correct JAVA_HOME, then PHOTOSPHERE_JDK17_HOME, then common paths.
if ! java_is_17 "${JAVA_HOME:-}"; then
    for candidate in \
        "${PHOTOSPHERE_JDK17_HOME:-}" \
        /usr/lib/jvm/java-17-openjdk-amd64 \
        /usr/lib/jvm/java-17-openjdk \
        /usr/lib/jvm/temurin-17-jdk-amd64 \
        /Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home \
        "$HOME"/.jdks/*17* \
        "$HOME"/.gradle/jdks/*17* \
        "$HOME"/.sdkman/candidates/java/17*; do
        if java_is_17 "$candidate"; then
            export JAVA_HOME="$candidate"
            break
        fi
    done
fi

if ! java_is_17 "${JAVA_HOME:-}"; then
    echo "ERROR: a JDK 17 is required to build the Android app (AGP fails on JDK 21)." >&2
    echo "Install one (e.g. 'sudo apt install openjdk-17-jdk') or set PHOTOSPHERE_JDK17_HOME / JAVA_HOME." >&2
    exit 1
fi

# Resolve the Android SDK so Gradle finds it without a local.properties.
export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
if [ ! -d "$ANDROID_HOME" ]; then
    echo "ERROR: Android SDK not found at '$ANDROID_HOME'. Set ANDROID_HOME to your SDK location." >&2
    exit 1
fi

cd "$REPO_ROOT/apps/android-frontend/android"
exec ./gradlew "$@"
