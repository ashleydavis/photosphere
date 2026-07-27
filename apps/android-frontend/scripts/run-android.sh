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
# Usage: apps/android-frontend/scripts/run-android.sh
#   PHOTOSPHERE_ANDROID_TARGET   deploy to a specific target when several are attached
#   PHOTOSPHERE_ANDROID_AVD      start a specific AVD (default: the only one, when there is one)
#   PHOTOSPHERE_NO_LAN_BRIDGE=1  start the emulator normally, without the LAN bridge
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# cap must run from the frontend, which is where capacitor.config lives.
cd "$APP_ROOT"
exec bunx cap run android --target "$target"
