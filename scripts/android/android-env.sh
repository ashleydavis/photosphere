#!/usr/bin/env bash
# Resolves the Android toolchain (a JDK 17 and the Android SDK) into the environment. Meant to be
# sourced, not executed, so the caller inherits the exports:
#
#   source ./android-env.sh
#
# This exists so `bun run` scripts work without the caller exporting JAVA_HOME / ANDROID_HOME. Shared
# by ./android-gradle.sh (Gradle tasks) and this app's `run` script (`cap run`), which both drive
# Gradle and so both need the same toolchain.
#
# Exits non-zero with a clear message when either piece is missing, which beats the errors the tools
# themselves give: Gradle says only "JAVA_HOME is not set", and native-run says only
# "ERR_SDK_NOT_FOUND", neither of which tells you what to install or where it looked.

# True when the given path is a JDK 17 installation.
java_is_17() {
    [ -n "${1:-}" ] && [ -x "$1/bin/java" ] && "$1/bin/java" -version 2>&1 | grep -q 'version "17'
}

# Select a JDK 17: honor an already-correct JAVA_HOME, then PHOTOSPHERE_JDK17_HOME, then common paths.
# AGP fails on the JDK 21 that Android Studio bundles, so 17 specifically is required. The list is a
# glob sweep rather than a single path because the JDK lands somewhere different depending on how it
# was installed (distro package, JetBrains .jdks, Gradle's own cache, sdkman, Homebrew on macOS).
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

# Gradle invokes the JDK by name in some paths, so put it on PATH as well as exporting JAVA_HOME.
export PATH="$JAVA_HOME/bin:$PATH"

# Resolve the Android SDK. Gradle can find it via android/local.properties, but native-run (which
# `cap run` shells out to for the deploy) only reads the environment, so this must be exported or
# `cap run` dies with ERR_SDK_NOT_FOUND even when Gradle builds fine.
#
# The default location differs by platform, so both are tried rather than only the Linux one. This
# mirrors what apps/smoke-tests/lib/android.sh already does, so `test:and` and `test:and:unit` resolve
# the SDK the same way instead of one working on a Mac and the other not.
#
export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$ANDROID_HOME" ]; then
    for candidate in "$HOME/Android/Sdk" "$HOME/Library/Android/sdk"; do
        if [ -d "$candidate" ]; then
            export ANDROID_HOME="$candidate"
            break
        fi
    done
fi
if [ -z "$ANDROID_HOME" ] || [ ! -d "$ANDROID_HOME" ]; then
    echo "ERROR: Android SDK not found at '$ANDROID_HOME' (tried \$HOME/Android/Sdk and \$HOME/Library/Android/sdk). Set ANDROID_HOME to your SDK location." >&2
    exit 1
fi

# Some native-run versions read ANDROID_SDK_ROOT in preference to ANDROID_HOME, so set both rather
# than depending on which one a given tool happens to check.
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"
