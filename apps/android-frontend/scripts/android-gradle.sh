#!/usr/bin/env bash
# Runs the Android app's Gradle with a JDK 17 and the Android SDK resolved, so native Gradle tasks
# (e.g. `bun run test:and:unit`) work without the caller exporting JAVA_HOME / ANDROID_HOME.
# AGP fails on the JDK 21 that Android Studio bundles, so a JDK 17 is required; this mirrors the
# ensure_jdk17 discovery the smoke-test harness uses.
#
# Usage: apps/android-frontend/scripts/android-gradle.sh <gradle-task> [args...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# The JDK 17 / Android SDK discovery, shared with the `run` script (`cap run` drives Gradle, so it
# needs the same toolchain).
source "$SCRIPT_DIR/android-env.sh"

cd "$APP_ROOT/android"
exec ./gradlew "$@"
