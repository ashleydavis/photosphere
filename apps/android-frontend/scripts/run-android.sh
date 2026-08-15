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
# Only two things are ever deployed to: a real device plugged in over USB, and the single
# hand-testing emulator. A plugged-in device wins, because the reason to have one attached is to test
# on it. Nothing else is a candidate, so a running smoke-test pool, a base AVD kept as a template for
# cloning, or an emulator somebody started for another job all stay untouched.
#
# Usage: apps/android-frontend/scripts/run-android.sh [fixture]
#   [fixture]                    50 | 1 | 0, or a directory name under test/dbs (e.g. 1-video, v6)
#   PHOTOSPHERE_ANDROID_TARGET   deploy to a specific target, whatever is attached
#   PHOTOSPHERE_ANDROID_AVD      use a specific AVD as the emulator (default: psphere-single)
#   PHOTOSPHERE_NO_LAN_BRIDGE=1  start the emulator normally, without the LAN bridge
#
# The fixture works the same on an emulator and on a plugged-in physical device: it goes over
# `adb push` and `run-as`, which need only that the installed build is debuggable, and the debug APK
# is. On a phone, plug it in with USB debugging authorised and it is chosen ahead of the emulator.
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

# Where the deploy's output is kept, so a failed deploy can be read after the fact. It stays on
# screen as well, because the deploy is the slow part of a run.
CAP_RUN_LOG="/tmp/photosphere-cap-run.log"

# The APK the Gradle build inside `cap run` produces. Checked against what is on the device to tell
# whether a deploy that reported failure actually installed this build.
APK_PATH="$APP_ROOT/android/app/build/outputs/apk/debug/app-debug.apk"

# The native-run binary `cap run` shells out to for the deploy, resolved from the root node_modules
# because the workspace hoists it there. Run directly (rather than only through cap) to ask it what
# targets it can see, which is what cap validates --target against.
NATIVE_RUN="$REPO_DIR/node_modules/native-run/bin/native-run"

# The network card the emulator plugs into to reach the host, from the one file that defines it.
#
# This used to be a local copy reading "tap-psphere", which the bridge script has never created. The
# check below therefore never matched, so this script silently started every emulator off the bridge
# even when one was up. Sourcing the name is what stops that happening again.
source "$SCRIPT_DIR/emulator-config.sh"
NETCARD_NAME="$NETCARD_PREFIX-0"

# The AVD the emulator half of this script starts and deploys to: the hand-testing one, by name.
# Naming it is what keeps the pool's clones and the base AVD out of the running, and it is used both
# to start the emulator and to recognise it once it is attached, so those two can never disagree.
RUN_AVD="${PHOTOSPHERE_ANDROID_AVD:-$SINGLE_AVD_NAME}"

#
# Prints the serial of every attached real device. Deliberately ignores "offline" and "unauthorized"
# entries, which would otherwise be selected and then fail confusingly.
#
# A local emulator is always called "emulator-<port>" by adb, so anything else attached is a real
# device. A device reached over the network (`adb connect`) is called "<host>:<port>" and so counts
# as a real device here, which is what it is.
#
hardware_targets() {
    "$ADB" devices | awk 'NR>1 && $2=="device" && $1 !~ /^emulator-/ { print $1 }'
}

#
# Prints the serial of the attached emulator running RUN_AVD, and nothing when it is not running.
#
# Emulators are matched by the AVD they are running rather than by being "the attached emulator", so
# the smoke-test pool's clones are never deployed to: they are not yours to deploy to, because a run
# in progress owns them and installing over one corrupts that run. The smoke-test harness applies the
# same rule in the other direction (android_pool_devices in apps/smoke-tests/lib/android.sh leaves a
# hand-started emulator alone).
#
emulator_target() {
    local serial avd
    for serial in $("$ADB" devices | awk 'NR>1 && $2=="device" && $1 ~ /^emulator-/ { print $1 }'); do
        # Capped, because an emulator that has stopped answering its console would otherwise hang the
        # whole run here rather than failing it.
        avd="$(timeout 8 "$ADB" -s "$serial" emu avd name 2>/dev/null | head -1 | tr -d '\r')"
        if [ "$avd" = "$RUN_AVD" ]; then
            echo "$serial"
        fi
    done
}

#
# Starts the hand-testing emulator and waits for it to finish booting, creating its AVD first if a
# fresh machine has none. Deploying the app does not need the LAN bridge, so this never brings the
# bridge up and never runs sudo: it attaches to the bridge only when it happens to be up already, and
# otherwise starts without it. That is what lets a plain `bun run run` work on a clean clone with no
# separate step. Bring the bridge up with `bun run emu:and:up` when you actually need LAN sharing (the
# host-to-device LAN-share tests); -wifi-tap looks like it would share the LAN and is accepted without
# complaint, but is silently ignored, so the bridge attach below uses -net-tap.
start_emulator() {
    if [ ! -x "$EMULATOR" ]; then
        echo "ERROR: emulator not found at $EMULATOR" >&2
        exit 1
    fi

    # Named outright rather than worked out from what exists, so which emulator this deploys to never
    # depends on which other AVDs happen to be on the machine. Create it if a fresh machine has none,
    # using the unprivileged slice of emu:and:up (no bridge, no sudo).
    local avd="$RUN_AVD"
    if ! "$EMULATOR" -list-avds 2>/dev/null | grep -qx "$avd"; then
        echo "Creating the '$avd' AVD (first run; no sudo, no bridge)..."
        bash "$SCRIPT_DIR/emulator.sh" ensure-single-avd || exit 1
    fi

    # Attach to the bridge only when it is already up; never bring it up here. Without the bridge the
    # app still installs and runs, it just cannot do host-to-device LAN sharing.
    local net_args=()
    if [ "${PHOTOSPHERE_NO_LAN_BRIDGE:-}" != "1" ] && ip link show "$NETCARD_NAME" >/dev/null 2>&1; then
        net_args=(-net-tap "$NETCARD_NAME")
        echo "Starting '$avd' on the LAN bridge ($NETCARD_NAME)..."
    else
        echo "Starting '$avd' (no LAN bridge; run 'bun run emu:and:up' if you want LAN sharing)..."
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
# Prints the checksum of the APK this run built. Matches android_apk_checksum in
# apps/smoke-tests/lib/android.sh, which identifies a build the same way for the same reason: the
# bytes are the only thing that says which build this is, since every checkout produces the same
# applicationId and version.
#
built_apk_checksum() {
    sha256sum "$APK_PATH" | cut -d' ' -f1
}

#
# Prints the checksum of the APK installed on the chosen target, computed on the device, or nothing
# when the app is not installed or the device cannot be reached. `adb install` copies the APK
# unchanged, so this is comparable with built_apk_checksum byte for byte.
#
installed_apk_checksum() {
    local remote_apk
    remote_apk="$("$ADB" -s "$target" shell pm path "$APP_ID" 2>/dev/null | tr -d '\r' | head -1 | sed 's/^package://')"
    if [ -z "$remote_apk" ]; then
        return 0
    fi
    "$ADB" -s "$target" shell sha256sum "$remote_apk" 2>/dev/null | tr -d '\r' | cut -d' ' -f1
}

#
# Returns 0 when native-run can see the chosen target.
#
# This is asked separately from adb because `cap run --target` validates the id against native-run's
# list rather than against adb, and the two disagree more often than they look like they should:
# native-run puts a 5 second timeout on every adb call it makes and, when one is exceeded, runs
# `adb kill-server` and `adb start-server` and retries against devices that are still
# re-authorizing, so a listing can come back with nothing attached at all. Capacitor then throws
# native-run's error away (it only reports one when the AVD list is empty as well) and says
# "Invalid target ID: <serial>. Valid targets are: <every AVD on the machine>", which reads as though
# the device had never been plugged in.
#
native_run_sees_target() {
    "$NATIVE_RUN" android --list --json 2>/dev/null \
        | jq -e --arg id "$target" '[.devices[]?.id] | index($id) != null' >/dev/null 2>&1
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

target="${PHOTOSPHERE_ANDROID_TARGET:-}"
if [ -z "$target" ]; then
    # A real device first: having one plugged in is what says you want to test on it. Only when there
    # is none does the emulator come into it, and then only the hand-testing one.
    targets="$(hardware_targets)"
    target_count="$(echo "$targets" | grep -c . || true)"

    if [ "$target_count" -gt 1 ]; then
        echo "ERROR: more than one device attached. Set PHOTOSPHERE_ANDROID_TARGET to one of:" >&2
        echo "$targets" | sed 's/^/  /' >&2
        exit 1
    fi

    if [ "$target_count" -eq 0 ]; then
        targets="$(emulator_target)"
        target_count="$(echo "$targets" | grep -c . || true)"
    fi

    if [ "$target_count" -eq 0 ]; then
        start_emulator
        disable_guest_wifi
        targets="$(emulator_target)"
        target_count="$(echo "$targets" | grep -c . || true)"
    fi

    if [ "$target_count" -eq 0 ]; then
        echo "ERROR: '$RUN_AVD' booted but adb sees no emulator running it." >&2
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
#
# The deploy is judged by the state it leaves the device in, not by its exit code. `cap run` shells
# out to native-run, which puts a hard-coded 5 second timeout on every adb call it makes, including
# the `am start -W` that waits for the activity to be displayed. This app takes longer than that to
# start after an install (measured at about 6 seconds), so native-run decides adb is unresponsive,
# runs `adb kill-server` and `adb start-server`, and retries against a device that has not finished
# re-authorizing. That retry fails, so cap run exits non-zero having built, installed and launched
# the app successfully.
#
# So a failure is only accepted when the device is demonstrably in the state a successful deploy
# leaves it in: this run's APK installed, compared byte for byte, and the app running. That is a
# check on the outcome rather than on the wording of native-run's error, which matters because the
# 5 second timeout also covers calls made before the install (`adb devices`, `getprop`): matching
# the error text alone would accept a run that never installed anything and leave you hand-testing
# whatever build happened to be on the device already.
if [ ! -x "$NATIVE_RUN" ]; then
    echo "ERROR: native-run not found at $NATIVE_RUN. Run 'bun install' from the repo root." >&2
    exit 1
fi

# Retried, because it is the listing that is unreliable and not the device: adb has the target
# attached, so a second look a few seconds later almost always has it too. Failing here is worth the
# wait, because the alternative is cap's "Invalid target ID" naming every AVD on the machine.
for list_attempt in $(seq 1 5); do
    if native_run_sees_target; then
        break
    fi
    if [ "$list_attempt" -eq 5 ]; then
        echo "ERROR: native-run cannot see $target, so 'cap run --target' would reject it." >&2
        echo "adb has it attached. This is what native-run sees:" >&2
        "$NATIVE_RUN" android --list >&2 || true
        exit 1
    fi
    sleep 3
done

cd "$APP_ROOT"
cap_status=0
bunx cap run android --target "$target" 2>&1 | tee "$CAP_RUN_LOG" || cap_status=$?

if [ "$cap_status" -ne 0 ]; then
    # native-run restarts the adb server on its way out, so the device is part way through
    # re-authorizing and cannot be asked anything yet. Bounded, because an unbounded wait turns a
    # device that never comes back into a run that hangs rather than one that fails; the checks
    # below report the failure either way.
    timeout 60 "$ADB" -s "$target" wait-for-device || true

    built_checksum="$(built_apk_checksum)"
    installed_checksum=""
    deploy_verified=""
    for _attempt in $(seq 1 15); do
        installed_checksum="$(installed_apk_checksum)"
        if [ "$installed_checksum" = "$built_checksum" ] && "$ADB" -s "$target" shell pidof "$APP_ID" >/dev/null 2>&1; then
            deploy_verified="1"
            break
        fi
        sleep 2
    done

    if [ -z "$deploy_verified" ]; then
        echo "ERROR: the deploy to $target failed. Output: $CAP_RUN_LOG" >&2
        if [ "$installed_checksum" != "$built_checksum" ]; then
            echo "The APK on $target is not the one this run built (installed: ${installed_checksum:-none}, built: $built_checksum)." >&2
        else
            echo "This run's APK is installed on $target but the app is not running." >&2
        fi
        exit "$cap_status"
    fi

    echo "cap run reported a failure, but this run's APK is installed on $target and the app is running."
    echo "(native-run's 5s adb timeout is shorter than this app's start; see $CAP_RUN_LOG.)"
fi

if [ -n "$FIXTURE_DB" ] && [ -z "$seed_first" ]; then
    seed_fixture
    register_fixture
fi

if [ -n "$FIXTURE_DB" ]; then
    echo
    echo "'test-$FIXTURE_DB' is in the app's database list on $target. Tap it to open it."
    echo
fi
