#!/usr/bin/env bash
# Builds and deploys the Android app, starting an emulator first if nothing is attached.
#
# Two things this handles that `cap run android` alone does not:
#
# 1. `cap run` asks "Please choose a target device" interactively. bun runs package scripts without a
#    TTY, so that prompt can never be answered: the run exits having built everything and deployed
#    nothing. Passing --target explicitly skips it. It prompts even with one emulator running,
#    because native-run offers both the running emulator and the AVD it could boot as choices.
#
# 2. The emulator has to be started a specific way for LAN sharing to work, and starting it any other
#    way (Android Studio, a bare `emulator -avd`) silently breaks sharing in a way that only shows up
#    60 seconds later as "No sender connected". See emulator.md for why. Rather than leave
#    that to memory, this starts it correctly when nothing is attached.
#
# Given a fixture it also copies one of the checked-in test databases into the app's storage and
# registers it in the app's databases.toml, so it is in the database list when the app starts and is
# opened by tapping it. That is the same thing registering a database in
# ~/.config/photosphere/databases.toml does on desktop.
#
# Usage: apps/android-frontend/scripts/run-android.sh [fixture]
#   [fixture]                    50 | 1 | 0, or a directory name under test/dbs (e.g. 1-video, v6)
#   PHOTOSPHERE_ANDROID_TARGET   deploy to a specific target when several are attached
#   PHOTOSPHERE_ANDROID_AVD      start a specific AVD (default: the only one, when there is one)
#   PHOTOSPHERE_NO_LAN_BRIDGE=1  start the emulator normally, without the LAN bridge
#
# The fixture works the same on an emulator and on a plugged-in physical device: it goes over
# `adb push` and `run-as`, which need only that the installed build is debuggable, and the debug APK
# is. On a phone, plug it in with USB debugging authorised and it is chosen like any other target.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$APP_ROOT/../.." && pwd)"

# Must match capacitor.config.ts. run-as addresses the app by this id.
APP_ID="au.com.codecapers.photosphere"

# The app's databases config, relative to its storage sandbox. The mobile counterpart of desktop's
# ~/.config/photosphere/databases.toml, in the same format. Must match DATABASES_CONFIG_PATH in
# packages/mobile-frontend/src/lib/mobile-databases-config-file.ts, which is what reads it.
DATABASES_CONFIG="databases.toml"

# Resolves JAVA_HOME (a JDK 17) and ANDROID_HOME, which both the Gradle build and native-run need.
source "$SCRIPT_DIR/android-env.sh"

ADB="$ANDROID_HOME/platform-tools/adb"
EMULATOR="$ANDROID_HOME/emulator/emulator"

# The network card the emulator plugs into to reach the host, from the one file that defines it.
#
# This used to be a local copy reading "tap-psphere", which the bridge script has never created. The
# check below therefore never matched, so this script silently started every emulator off the bridge
# even when one was up. Sourcing the name is what stops that happening again.
source "$SCRIPT_DIR/emulator-config.sh"
NETCARD_NAME="$NETCARD_PREFIX-0"

#
# Prints the ids of every target adb can actually deploy to. Deliberately ignores "offline" and
# "unauthorized" entries, which would otherwise be selected and then fail confusingly.
#
# Emulators belonging to the smoke-test pool are skipped, because they are not yours to deploy to:
# a run in progress owns them, and installing over one corrupts that run. The smoke-test harness
# already applies this rule in the other direction (android_pool_devices in
# apps/smoke-tests/lib/android.sh leaves a hand-started emulator alone), so without this the rule
# only held one way: any pool running in the background turned a single unambiguous choice into
# "more than one target attached" and stopped hand testing dead.
#
attached_targets() {
    local serial avd
    for serial in $("$ADB" devices | awk 'NR>1 && $2=="device" { print $1 }'); do
        avd="$("$ADB" -s "$serial" emu avd name 2>/dev/null | head -1 | tr -d '\r')"
        case "$avd" in
            "$POOL_AVD_PREFIX"-*) ;;
            *) echo "$serial" ;;
        esac
    done
}

#
# Starts an emulator and waits for it to finish booting.
#
# When the LAN bridge is up it attaches the emulator to it with -net-tap, which is what lets the host
# and the emulator see each other's broadcast traffic. -wifi-tap looks like it should do this and is
# accepted without complaint, but is silently ignored, so do not be tempted to switch to it.
#
start_emulator() {
    if [ ! -x "$EMULATOR" ]; then
        echo "ERROR: emulator not found at $EMULATOR" >&2
        exit 1
    fi

    local avd="${PHOTOSPHERE_ANDROID_AVD:-}"
    if [ -z "$avd" ]; then
        local avds
        avds="$("$EMULATOR" -list-avds 2>/dev/null | grep -v '^$' || true)"
        local avd_count
        avd_count="$(echo "$avds" | grep -c . || true)"
        if [ "$avd_count" -eq 0 ]; then
            echo "ERROR: no AVDs exist. Create one in Android Studio's Device Manager." >&2
            exit 1
        fi
        if [ "$avd_count" -gt 1 ]; then
            echo "ERROR: several AVDs exist. Set PHOTOSPHERE_ANDROID_AVD to one of:" >&2
            echo "$avds" | sed 's/^/  /' >&2
            exit 1
        fi
        avd="$avds"
    fi

    # Only attach to the bridge when it is actually there. Without this check the emulator fails to
    # start at all when the bridge is down, which would make the app impossible to run for anyone who
    # does not care about LAN sharing.
    local net_args=()
    if [ "${PHOTOSPHERE_NO_LAN_BRIDGE:-}" != "1" ] && ip link show "$NETCARD_NAME" >/dev/null 2>&1; then
        net_args=(-net-tap "$NETCARD_NAME")
        echo "Starting '$avd' on the LAN bridge ($NETCARD_NAME)..."
    else
        echo "Starting '$avd' (no LAN bridge; run 'bun run emu:and:up' first if you want LAN sharing)..."
    fi

    # setsid detaches the emulator so it outlives this script: the deploy below, and everything you
    # do afterwards, needs it to stay up.
    setsid nohup "$EMULATOR" -avd "$avd" "${net_args[@]}" > /tmp/photosphere-emulator.log 2>&1 < /dev/null &

    echo "Waiting for it to boot (log: /tmp/photosphere-emulator.log)..."
    if ! timeout 300 bash -c "until [ \"\$('$ADB' shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')\" = \"1\" ]; do sleep 3; done"; then
        echo "ERROR: emulator did not finish booting within 5 minutes. See /tmp/photosphere-emulator.log" >&2
        exit 1
    fi
    echo "Booted."
}

#
# Turns off the emulator's wifi when it is on the LAN bridge.
#
# The emulator keeps wlan0 on its own isolated NAT even with -net-tap, so the guest ends up with two
# interfaces on the same subnet and Android answers over the wrong one. Disabling wifi leaves eth0,
# which is the one plugged into the bridge, as the only path. This does not persist across a reboot
# of the emulator, which is exactly why it belongs here rather than in a list of steps to remember.
#
disable_guest_wifi() {
    if [ "${PHOTOSPHERE_NO_LAN_BRIDGE:-}" = "1" ] || ! ip link show "$NETCARD_NAME" >/dev/null 2>&1; then
        return 0
    fi

    "$ADB" shell svc wifi disable >/dev/null 2>&1 || true
    echo "Disabled the emulator's wifi so it uses the LAN bridge."
}

#
# Maps the short fixture names the package scripts use to the directories under test/dbs. Anything
# not listed is passed through unchanged, so a fixture the shorthands do not cover (1-video, v6,
# multi-set) still works without editing this script.
#
fixture_dir_name() {
    case "$1" in
        50) echo "50-assets" ;;
        1)  echo "1-asset" ;;
        0)  echo "no-assets" ;;
        *)  echo "$1" ;;
    esac
}

#
# Returns 0 when the app is installed on the chosen target.
#
app_installed() {
    "$ADB" -s "$target" shell pm list packages "$APP_ID" 2>/dev/null | tr -d '\r' | grep -q "^package:$APP_ID$"
}

#
# Copies the fixture database into the app's private files directory: the sandbox root the native
# PathSandbox resolves paths against, which is why the app opens it by a plain relative name.
#
# The host path is pushed to a world-readable temp location first, then copied in with run-as, which
# is the only way to write app-private storage (and works because the debug build is debuggable).
# Each step is a single adb shell command with no shell operators, because `adb shell` re-splits the
# remote command on spaces and mangles `sh -c "...&&..."` quoting. run-as runs in the app's data
# directory, so the destination is relative to that.
#
# This mirrors android_seed_database in apps/smoke-tests/lib/android.sh, written out again rather
# than shared because that file is a smoke-test library that assumes the harness's environment
# (ANDROID_SERIAL binding, log_info, APP_ID from common.sh). A dozen lines of overlap beats dragging
# the whole harness into a hand-testing script.
#
seed_fixture() {
    local tmp_remote="/data/local/tmp/$FIXTURE_DB"
    echo "Seeding the '$FIXTURE_DB' database into the app's storage..."
    "$ADB" -s "$target" shell rm -rf "$tmp_remote" >/dev/null 2>&1 || true
    "$ADB" -s "$target" push "$FIXTURE_SRC" /data/local/tmp/ >/dev/null
    "$ADB" -s "$target" shell run-as "$APP_ID" rm -rf "files/$FIXTURE_DB"
    "$ADB" -s "$target" shell run-as "$APP_ID" cp -r "$tmp_remote" "files/$FIXTURE_DB"
    "$ADB" -s "$target" shell rm -rf "$tmp_remote" >/dev/null 2>&1 || true
}

#
# Registers the seeded database in the app's databases.toml, so it is in the database list when the
# app starts and is opened by tapping it.
#
# This is the same move as registering a database in ~/.config/photosphere/databases.toml on desktop:
# write the config, the app reads it. Mobile's copy lives in the app's storage sandbox, in the same
# format (see packages/node-api/src/lib/databases-config-mobile.worker.ts).
#
# Existing entries are preserved and one matching this fixture's name is replaced, so running for one
# fixture never drops another. The merge happens here because the file is rewritten whole either way,
# and there is no TOML tooling on an emulator.
#
register_fixture() {
    local registry="files/$DATABASES_CONFIG"
    local existing tmp_local

    # A missing file is the normal state of a device with no databases registered, and starts from
    # empty. A file that exists but cannot be read is a different thing entirely, and stops the run:
    # treating it as empty would rewrite the config having never seen what was in it.
    if "$ADB" -s "$target" shell run-as "$APP_ID" ls "$registry" >/dev/null 2>&1; then
        if ! existing="$("$ADB" -s "$target" shell run-as "$APP_ID" cat "$registry")"; then
            echo "ERROR: $registry exists on $target but could not be read. Refusing to overwrite it." >&2
            exit 1
        fi
    else
        existing=""
    fi

    tmp_local="$(mktemp)"
    FIXTURE_DB="$FIXTURE_DB" EXISTING="$existing" bun "$SCRIPT_DIR/write-databases-config.ts" "$tmp_local"

    # Pushed via the shared temp directory, because adb push cannot write app-private storage directly.
    "$ADB" -s "$target" push "$tmp_local" "/data/local/tmp/$DATABASES_CONFIG" >/dev/null
    "$ADB" -s "$target" shell run-as "$APP_ID" cp "/data/local/tmp/$DATABASES_CONFIG" "$registry"
    "$ADB" -s "$target" shell rm -f "/data/local/tmp/$DATABASES_CONFIG" >/dev/null 2>&1 || true
    rm -f "$tmp_local"

    echo "Registered 'test-$FIXTURE_DB' in the app's database list ($DATABASES_CONFIG)."
}

# Resolve the fixture before anything slow happens, so a bad name fails immediately rather than after
# a full build and deploy.
FIXTURE_DB=""
FIXTURE_SRC=""
if [ $# -gt 0 ]; then
    FIXTURE_DB="$(fixture_dir_name "$1")"
    FIXTURE_SRC="$REPO_DIR/test/dbs/$FIXTURE_DB"
    if [ ! -d "$FIXTURE_SRC" ]; then
        echo "ERROR: no fixture database at test/dbs/$FIXTURE_DB. Available:" >&2
        ls "$REPO_DIR/test/dbs" | sed 's/^/  /' >&2
        exit 1
    fi
fi

targets="$(attached_targets)"
target_count="$(echo "$targets" | grep -c . || true)"

if [ "$target_count" -eq 0 ]; then
    start_emulator
    disable_guest_wifi
    targets="$(attached_targets)"
    target_count="$(echo "$targets" | grep -c . || true)"
fi

if [ "$target_count" -eq 0 ]; then
    echo "ERROR: emulator booted but adb still sees no target." >&2
    exit 1
fi

target="${PHOTOSPHERE_ANDROID_TARGET:-}"
if [ -z "$target" ]; then
    if [ "$target_count" -gt 1 ]; then
        echo "ERROR: more than one target attached. Set PHOTOSPHERE_ANDROID_TARGET to one of:" >&2
        echo "$targets" | sed 's/^/  /' >&2
        exit 1
    fi
    target="$targets"
fi

echo "Deploying to $target"

# Seeding needs the app installed, because run-as only works on an installed package. When it
# already is (every run but the first on a given device) seed first, so the deploy stays the last
# thing this script does. Otherwise the deploy has to come first and the seed follows it.
seed_first=""
if [ -n "$FIXTURE_DB" ] && app_installed; then
    seed_fixture
    register_fixture
    seed_first="1"
fi

# cap must run from the frontend, which is where capacitor.config lives.
cd "$APP_ROOT"
bunx cap run android --target "$target"

if [ -n "$FIXTURE_DB" ] && [ -z "$seed_first" ]; then
    seed_fixture
    register_fixture
fi

if [ -n "$FIXTURE_DB" ]; then
    echo
    echo "'test-$FIXTURE_DB' is in the app's database list on $target. Tap it to open it."
    echo
fi
