#!/usr/bin/env bash
# Installs the Android command-line toolchain needed to build, deploy, and run this app on an emulator
# or a device, without the Android Studio IDE. It downloads Google's command-line tools, then uses
# sdkmanager to fetch exactly what the Gradle build and the emulator need: platform-tools (adb), the
# compile platform, the matching build-tools, the pinned NDK, cmake for the native ImageMagick shim,
# and the emulator plus a system image so a fresh machine can run the app without a physical device.
#
# Usage:
#   bash ./scripts/install-android-sdk.sh            # print this help and change nothing
#   bash ./scripts/install-android-sdk.sh --status   # report what is already installed, change nothing
#   bash ./scripts/install-android-sdk.sh --install  # download and install the toolchain
#
# Everything lands under a single SDK directory ($HOME/Android/Sdk on Linux), which is exactly where
# android-env.sh looks, so `bun run run` works afterwards with no extra configuration. The install is
# reversible: delete that directory to undo it. A JDK 17 is required to run sdkmanager; --install
# installs one automatically (via apt on Debian/Ubuntu, which prompts for sudo) when none is found.

set -euo pipefail

# The SDK package versions, kept in step with android/variables.gradle and android/app/build.gradle.
# compileSdkVersion 33 -> platforms;android-33 and build-tools;33.0.2 (the last 33.x build-tools).
# ndkVersion and the cmake version are copied verbatim from android/app/build.gradle.
ANDROID_PLATFORM="platforms;android-33"
ANDROID_BUILD_TOOLS="build-tools;33.0.2"
ANDROID_NDK="ndk;25.1.8937393"
ANDROID_CMAKE="cmake;3.22.1"

# The emulator's system image. The API level matches what scripts/emulator.sh builds its base AVD
# from: create_base_avd picks the highest installed system image, and the image it documents to
# install is android-34 google_apis x86_64, so installing that is what lets `emu:and:up` create an
# AVD. x86_64 is the emulator ABI on an x86_64 host and is one of the app's built ABIs.
ANDROID_SYSTEM_IMAGE="system-images;android-34;google_apis;x86_64"

# Everything --install fetches and --status checks for: the packages the Gradle build reaches for,
# plus the emulator and its system image so the app can run on an emulator, not only a physical
# device. One list, so install and status can never drift apart.
REQUIRED_PACKAGES=(
    "platform-tools"
    "$ANDROID_PLATFORM"
    "$ANDROID_BUILD_TOOLS"
    "$ANDROID_NDK"
    "$ANDROID_CMAKE"
    "emulator"
    "$ANDROID_SYSTEM_IMAGE"
)

# The command-line tools build to download. Google publishes these only under a build number, with no
# stable "latest" alias, so it is pinned here and overridable for when a newer one is wanted.
CMDLINE_TOOLS_VERSION="${PHOTOSPHERE_CMDLINE_TOOLS_VERSION:-11076708}"

# Print the leading comment block of this file as help: skip the shebang, strip the "# " prefix, and
# stop at the first line that is not a comment so the rest of the script is not dumped.
print_help() {
    local line stripped
    while IFS= read -r line; do
        case "$line" in
            '#!'*)
                continue
                ;;
            '#'*)
                stripped="${line#\#}"
                printf '%s\n' "${stripped# }"
                ;;
            *)
                break
                ;;
        esac
    done < "$0"
}

# The requested actions. Collected as flags rather than a single last-wins value so precedence is
# deliberate: --status wins over --install when both are given. That makes a read-only status check
# the safe interpretation of a contradictory request, and lets `bun run setup --status` override the
# --install that the package's `setup` script bakes in.
WANT_INSTALL=0
WANT_STATUS=0
for arg in "$@"; do
    case "$arg" in
        --install)
            WANT_INSTALL=1
            ;;
        --status)
            WANT_STATUS=1
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument '$arg' (try --help)." >&2
            exit 1
            ;;
    esac
done

# Resolve the flags to a single mode, --status taking precedence. Empty means no action was requested,
# which prints help and changes nothing, so a bare run never installs anything by surprise.
if [ "$WANT_STATUS" -eq 1 ]; then
    MODE="status"
elif [ "$WANT_INSTALL" -eq 1 ]; then
    MODE="install"
else
    MODE=""
fi

if [ -z "$MODE" ]; then
    print_help
    exit 0
fi

# The download slug and default SDK location differ by OS, mirroring the two candidates android-env.sh
# already probes so the installed SDK is found without any extra configuration.
case "$(uname -s)" in
    Linux)
        TOOLS_OS="linux"
        DEFAULT_SDK_DIR="$HOME/Android/Sdk"
        ;;
    Darwin)
        TOOLS_OS="mac"
        DEFAULT_SDK_DIR="$HOME/Library/Android/sdk"
        ;;
    *)
        echo "ERROR: unsupported OS '$(uname -s)'. This installer handles Linux and macOS only." >&2
        exit 1
        ;;
esac

# Honor an existing ANDROID_HOME / ANDROID_SDK_ROOT so a second run tops up the same SDK, otherwise
# fall back to the platform default.
ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$DEFAULT_SDK_DIR}}"

# True when the given path is a JDK 17 installation. Matches android-env.sh's check exactly, because
# sdkmanager runs on the same JDK the build later uses (AGP fails on JDK 21).
java_is_17() {
    [ -n "${1:-}" ] && [ -x "$1/bin/java" ] && "$1/bin/java" -version 2>&1 | grep -q 'version "17'
}

# Derive a JDK home from a `java` or `javac` binary on PATH: follow symlinks to the real binary, then
# go up two directories (bin/java -> the JDK home). This is what finds a JDK 17 that is usable as
# `java` on PATH but whose install location is not in the fixed candidate list below (a version
# manager, a distro symlink, or an unusual prefix), which the fixed list alone would miss.
jdk_home_from_path() {
    local binary_on_path real_binary
    binary_on_path="$(command -v "$1" 2>/dev/null)" || return 1
    real_binary="$(readlink -f "$binary_on_path" 2>/dev/null)" || return 1
    dirname "$(dirname "$real_binary")"
}

# Resolve a JDK 17. Honor JAVA_HOME, then the fixed install locations android-env.sh knows, then any
# java/javac already on PATH, so sdkmanager and the later build agree on the JDK (AGP fails on 21).
resolve_jdk17() {
    if java_is_17 "${JAVA_HOME:-}"; then
        return 0
    fi
    for candidate in \
        "${PHOTOSPHERE_JDK17_HOME:-}" \
        /usr/lib/jvm/java-17-openjdk-amd64 \
        /usr/lib/jvm/java-17-openjdk \
        /usr/lib/jvm/temurin-17-jdk-amd64 \
        /Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home \
        "$HOME"/.jdks/*17* \
        "$HOME"/.gradle/jdks/*17* \
        "$HOME"/.sdkman/candidates/java/17* \
        "$(jdk_home_from_path java)" \
        "$(jdk_home_from_path javac)"; do
        if java_is_17 "$candidate"; then
            export JAVA_HOME="$candidate"
            return 0
        fi
    done
    return 1
}

# The SDK path a package id installs to: sdkmanager lays each package out under the SDK with its ';'
# separators turned into directory separators (platforms;android-33 -> platforms/android-33).
package_install_path() {
    printf '%s/%s\n' "$ANDROID_HOME" "${1//;//}"
}

# Report one package as installed or missing, and count the missing ones into STATUS_MISSING so the
# caller can tell whether anything needs installing.
report_package() {
    if [ -e "$(package_install_path "$1")" ]; then
        printf '  [installed]  %s\n' "$1"
    else
        printf '  [ missing ]  %s\n' "$1"
        STATUS_MISSING=$((STATUS_MISSING + 1))
    fi
}

# --status: report what is already present without changing anything. Read-only, and it does not need
# a JDK or the command-line tools to run, so it works on a bare machine to show what is missing.
do_status() {
    echo "Android SDK status"
    echo "=================="
    echo "OS:           $(uname -s)"
    if [ -d "$ANDROID_HOME" ]; then
        echo "SDK location: $ANDROID_HOME (exists)"
    else
        echo "SDK location: $ANDROID_HOME (not created yet)"
    fi
    echo

    STATUS_MISSING=0

    # A JDK 17 is needed to run sdkmanager and to build; report the resolved home or that none was found.
    if resolve_jdk17; then
        printf '  [installed]  JDK 17 (%s)\n' "$JAVA_HOME"
    else
        printf '  [ missing ]  JDK 17\n'
        STATUS_MISSING=$((STATUS_MISSING + 1))
    fi

    # The command-line tools that provide sdkmanager itself.
    if [ -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]; then
        printf '  [installed]  command-line tools (sdkmanager)\n'
    else
        printf '  [ missing ]  command-line tools (sdkmanager)\n'
        STATUS_MISSING=$((STATUS_MISSING + 1))
    fi

    # The build and emulator packages, counted toward readiness.
    for package in "${REQUIRED_PACKAGES[@]}"; do
        report_package "$package"
    done

    echo
    if [ "$STATUS_MISSING" -eq 0 ]; then
        echo "Ready: everything required is installed. Run the app with 'bun run run'."
    else
        echo "$STATUS_MISSING required item(s) missing. Install them with:"
        echo "  bun run --filter=android-frontend setup"
    fi
}

# --install: download the command-line tools if needed and fetch the required packages.
do_install() {
    # Check the prerequisites this script itself needs to download and unpack the tools.
    for tool in curl unzip; do
        if ! command -v "$tool" > /dev/null 2>&1; then
            echo "ERROR: '$tool' is required but not installed. Install it and re-run." >&2
            exit 1
        fi
    done

    # A JDK 17 must exist before sdkmanager can run. Install one automatically when none is found: on
    # Debian/Ubuntu that means apt, which needs sudo and so prompts for a password (unavoidable for a
    # system package). Only when apt is not available does the script stop and ask you to install one.
    if ! resolve_jdk17; then
        if command -v apt-get > /dev/null 2>&1; then
            echo "No JDK 17 found; installing OpenJDK 17 via apt (sudo, will prompt for your password)..."
            sudo apt-get update
            sudo apt-get install -y openjdk-17-jdk
            if ! resolve_jdk17; then
                echo "ERROR: OpenJDK 17 was installed but could not be resolved. Set PHOTOSPHERE_JDK17_HOME." >&2
                exit 1
            fi
        else
            echo "ERROR: a JDK 17 is required to run sdkmanager (AGP also fails on JDK 21), and this is" >&2
            echo "not a Debian/Ubuntu system so it cannot be apt-installed automatically. Install a JDK 17" >&2
            echo "(from your package manager, or https://adoptium.net) and re-run." >&2
            exit 1
        fi
    fi

    # sdkmanager finds the JDK through JAVA_HOME and the java on PATH; export both, as android-env.sh does.
    export PATH="$JAVA_HOME/bin:$PATH"
    echo "Using JDK 17 at: $JAVA_HOME"
    echo "Installing the Android SDK into: $ANDROID_HOME"

    local sdkmanager="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"

    # Bootstrap the command-line tools only when they are not already present, so re-runs skip the
    # download and just top up packages.
    if [ ! -x "$sdkmanager" ]; then
        echo "Downloading command-line tools (build $CMDLINE_TOOLS_VERSION)..."
        # TEMP_DIR is a script global, not a function local, so the EXIT trap can still see it when the
        # shell exits (a local goes out of scope as the function returns, before the trap runs, which
        # under `set -u` would make the trap itself fail on an unbound variable).
        TEMP_DIR="$(mktemp -d)"
        # Clean the temp download directory on any exit, success or failure. Guard the expansion so the
        # trap is safe even if we exit before TEMP_DIR was assigned.
        trap 'if [ -n "${TEMP_DIR:-}" ]; then rm -rf "$TEMP_DIR"; fi' EXIT
        local zip_url="https://dl.google.com/android/repository/commandlinetools-${TOOLS_OS}-${CMDLINE_TOOLS_VERSION}_latest.zip"
        curl -fSL "$zip_url" -o "$TEMP_DIR/cmdline-tools.zip"
        unzip -q "$TEMP_DIR/cmdline-tools.zip" -d "$TEMP_DIR/extracted"

        # The zip unpacks to a top-level "cmdline-tools" directory, but sdkmanager expects to live under
        # cmdline-tools/latest/ within the SDK, so move it into place with that name.
        mkdir -p "$ANDROID_HOME/cmdline-tools"
        rm -rf "$ANDROID_HOME/cmdline-tools/latest"
        mv "$TEMP_DIR/extracted/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"

        if [ ! -x "$sdkmanager" ]; then
            echo "ERROR: sdkmanager not found at '$sdkmanager' after unpacking. The download may have changed shape." >&2
            exit 1
        fi
    else
        echo "Command-line tools already present, reusing them."
    fi

    # Accept the SDK licenses non-interactively first, otherwise the install prompts and stalls.
    # `yes` is killed by SIGPIPE once sdkmanager stops reading, which under `set -o pipefail` would make
    # the pipeline fail; disable pipefail just here so the pipeline's status is sdkmanager's own exit
    # code (a real sdkmanager failure is still caught), then restore it.
    echo "Accepting SDK licenses..."
    set +o pipefail
    yes | "$sdkmanager" --sdk_root="$ANDROID_HOME" --licenses > /dev/null
    set -o pipefail

    echo "Installing packages:"
    local package
    for package in "${REQUIRED_PACKAGES[@]}"; do
        echo "  - $package"
    done
    "$sdkmanager" --sdk_root="$ANDROID_HOME" "${REQUIRED_PACKAGES[@]}"

    echo
    echo "Done. The Android toolchain (including the emulator) is installed under $ANDROID_HOME."
    echo
    echo "Add adb to your PATH (once):"
    echo "  echo 'export PATH=\$PATH:$ANDROID_HOME/platform-tools' >> ~/.zshrc"
    echo
    echo "Run the app from apps/android-frontend with 'bun run run': it deploys to a plugged-in device"
    echo "(verify with 'adb devices'). To run on the emulator instead, bring it up first with"
    echo "'bun run emu:and:up' (creates the AVD and the LAN bridge; prompts for sudo)."
}

case "$MODE" in
    status)
        do_status
        ;;
    install)
        do_install
        ;;
esac
