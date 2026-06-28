#!/bin/bash

# Android launcher for mobile smoke tests. Sourced by common.sh when PLATFORM=android.
# Drives an Android emulator (or attached device) entirely from the host via adb; the bridge
# captures the screen with `adb exec-out screencap`.
#
# android_prepare sets up the toolchain automatically (detects ANDROID_HOME, puts adb/emulator
# on PATH, finds a JDK 17, and boots an emulator if none is attached), so `bun run test:android`
# works without manual environment setup. The only prerequisite that cannot be auto-installed is
# a JDK 17 (AGP 8.0 fails on the JDK 21 Android Studio bundles); see ensure_jdk17.

# Path to the debug APK produced by assembleDebug.
ANDROID_APK="$ANDROID_FRONTEND_DIR/android/app/build/outputs/apk/debug/app-debug.apk"

#
# Returns 0 if the given Java home is a JDK 17 installation.
#
java_is_17() {
    local java_home="$1"
    [ -n "$java_home" ] && [ -x "$java_home/bin/java" ] && "$java_home/bin/java" -version 2>&1 | grep -q 'version "17'
}

#
# Ensures JAVA_HOME points at a JDK 17. The Android build (AGP 8.0) fails on JDK 21 (the version
# Android Studio bundles), so a JDK 17 is required. Honors an already-correct JAVA_HOME, then a
# PHOTOSPHERE_JDK17_HOME override, then searches common install locations. Fails with a clear
# install hint if none is found.
#
ensure_jdk17() {
    if java_is_17 "${JAVA_HOME:-}"; then
        log_info "Using JDK 17 at $JAVA_HOME"
        return 0
    fi
    local candidate
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
            log_info "Using JDK 17 at $JAVA_HOME"
            return 0
        fi
    done
    log_error "A JDK 17 is required to build the Android app (AGP 8.0 fails on the JDK 21 that"
    log_error "Android Studio bundles). Install one, e.g.:  sudo apt install openjdk-17-jdk"
    log_error "Or set PHOTOSPHERE_JDK17_HOME (or JAVA_HOME) to a JDK 17 install."
    return 1
}

#
# Sets up the Android toolchain environment so `bun run test:android` works without manual
# exports: detects the SDK (ANDROID_HOME), puts platform-tools and emulator on PATH, and selects
# a JDK 17. Honors values already set in the environment.
#
android_setup_env() {
    if [ -z "${ANDROID_HOME:-}" ]; then
        if [ -d "$HOME/Android/Sdk" ]; then
            export ANDROID_HOME="$HOME/Android/Sdk"
        elif [ -d "$HOME/Library/Android/sdk" ]; then
            export ANDROID_HOME="$HOME/Library/Android/sdk"
        fi
    fi
    export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
    if [ -n "${ANDROID_HOME:-}" ]; then
        export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
    fi
    ensure_jdk17
}

#
# Returns 0 if an emulator/device is attached and reporting "device" state.
#
android_device_attached() {
    adb devices 2>/dev/null | awk 'NR>1 && $2=="device" {found=1} END {exit !found}'
}

#
# Sets up the environment, boots an emulator if none is attached, and waits for it to finish
# booting. The AVD is the first one found unless ANDROID_AVD is set.
#
android_prepare() {
    android_setup_env || return 1

    if ! command -v adb >/dev/null 2>&1; then
        log_error "adb not found. Install the Android SDK platform tools (or set ANDROID_HOME)."
        return 1
    fi

    if ! android_device_attached; then
        local avd
        avd="${ANDROID_AVD:-$(emulator -list-avds 2>/dev/null | head -1)}"
        if [ -z "$avd" ]; then
            log_error "No emulator attached and no AVD found. Create one in Android Studio's Device Manager."
            return 1
        fi
        log_info "No device attached; booting emulator '$avd' (left running for faster reruns)..."
        nohup emulator -avd "$avd" -no-boot-anim >/dev/null 2>&1 &
    fi

    log_info "Waiting for an Android device/emulator..."
    adb wait-for-device
    local booted=""
    local elapsed=0
    while [ "$elapsed" -lt 180 ]; do
        booted=$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
        if [ "$booted" = "1" ]; then
            log_info "Android device booted"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    log_error "Android device did not finish booting within 180s"
    return 1
}

#
# Builds the web assets, syncs Capacitor, and assembles the debug APK.
#
android_build() {
    log_info "Building Android app..."
    (cd "$ANDROID_FRONTEND_DIR" && bun run sync)
    (cd "$ANDROID_FRONTEND_DIR/android" && ./gradlew assembleDebug)
}

#
# Installs (or reinstalls) the debug APK on the device.
#
android_install() {
    if [ ! -f "$ANDROID_APK" ]; then
        log_error "APK not found at $ANDROID_APK (did android_build run?)"
        return 1
    fi
    log_info "Installing APK..."
    adb install -r "$ANDROID_APK"
}

#
# Launches the app in test mode pointing at the host control bridge.
# Usage: android_launch <port>
#
# The emulator reaches the host via the 10.0.2.2 alias (the reliable route; `adb reverse` to
# localhost is not dependable on the emulator's WebView network stack). `adb reverse` is still
# set so a physical device (which has no 10.0.2.2) can be targeted by passing localhost via
# PHOTOSPHERE_ANDROID_TEST_HOST.
#
android_launch() {
    local port="$1"
    adb reverse "tcp:$port" "tcp:$port"
    adb shell am start -n "$APP_ID/.MainActivity" \
        --ez photosphereTestMode true \
        --es photosphereTestHost "${PHOTOSPHERE_ANDROID_TEST_HOST:-10.0.2.2}" \
        --ei photosphereTestPort "$port"
}

#
# Force-stops the app and removes the port reverse.
# Usage: android_stop <port>
#
android_stop() {
    local port="$1"
    adb shell am force-stop "$APP_ID"
    if [ -n "$port" ]; then
        adb reverse --remove "tcp:$port" 2>/dev/null || true
    fi
}
