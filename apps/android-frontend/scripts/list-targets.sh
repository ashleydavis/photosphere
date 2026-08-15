#!/usr/bin/env bash
# Lists the Android run targets that `bun run and50` (and the other and*/run:and* scripts) can see,
# and shows which one a run would deploy to. Read-only: it starts nothing, installs nothing, and
# changes nothing. It applies the same hardware-first rule as scripts/run-android.sh, so what it
# reports is what a run would actually pick. If that rule changes there, change it here too.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The hand-testing AVD's name, so an attached emulator running it can be told apart from the smoke
# -test pool's clones (which are never a run target). Same source run-android.sh reads.
source "$SCRIPT_DIR/emulator-config.sh"
RUN_AVD="${PHOTOSPHERE_ANDROID_AVD:-$SINGLE_AVD_NAME}"

# Resolve the SDK's adb without needing a JDK (unlike android-env.sh): listing devices does not build
# anything. Honor ANDROID_HOME / ANDROID_SDK_ROOT, else the platform default the installer uses.
ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$ANDROID_HOME" ]; then
    for candidate in "$HOME/Android/Sdk" "$HOME/Library/Android/sdk"; do
        if [ -d "$candidate" ]; then
            ANDROID_HOME="$candidate"
            break
        fi
    done
fi
ADB="$ANDROID_HOME/platform-tools/adb"
if [ ! -x "$ADB" ]; then
    echo "ERROR: adb not found at '$ADB'. Install the SDK with 'bun run setup', or set ANDROID_HOME." >&2
    exit 1
fi

echo "Android run targets"
echo "==================="
echo

# The device rows adb prints, minus the header, the daemon-startup notes, and blank lines: each row is
# "<serial>\t<state>". NF>=2 keeps only real rows, and the two negative matches drop the header
# ("List of devices attached") and any "* daemon ..." line that reached stdout.
device_rows="$("$ADB" devices | awk 'NF>=2 && $1 != "List" && $1 !~ /^\*/' || true)"

if [ -z "$device_rows" ]; then
    echo "Nothing attached."
    echo
    echo "What 'bun run and50' would do:"
    echo "  Start the '$RUN_AVD' emulator (creating its AVD if missing) and deploy to it."
    echo
    echo "Plug in a device and accept the USB-debugging prompt to deploy to real hardware instead."
    exit 0
fi

# Categories. A real device is anything not named emulator-<port> (a network device from `adb connect`
# is "<host>:<port>" and counts as hardware, which is what it is). Emulators are split by the AVD they
# run: the single hand-testing one (RUN_AVD, what and* deploys to), the pool's clones (POOL_AVD_PREFIX
# -N, used by the smoke tests and never a run target), and anything else. Anything not in state
# "device" cannot be deployed to.
hardware_ready=()
emulator_single=()
emulator_pool=()
emulator_other=()
not_ready=()

while read -r serial state; do
    if [ -z "$serial" ]; then
        continue
    fi
    case "$serial" in
        emulator-*)
            if [ "$state" = "device" ]; then
                avd="$(timeout 8 "$ADB" -s "$serial" emu avd name 2>/dev/null | head -1 | tr -d '\r')"
                if [ "$avd" = "$RUN_AVD" ]; then
                    emulator_single+=("$serial (running '$avd')")
                elif [ -n "$avd" ] && [ "${avd#"$POOL_AVD_PREFIX"-}" != "$avd" ]; then
                    emulator_pool+=("$serial (running '$avd')")
                else
                    emulator_other+=("$serial (running '${avd:-unknown}')")
                fi
            else
                not_ready+=("$serial [emulator, $state]")
            fi
            ;;
        *)
            if [ "$state" = "device" ]; then
                hardware_ready+=("$serial")
            else
                not_ready+=("$serial [$state]")
            fi
            ;;
    esac
done <<< "$device_rows"

# Print one category, or "(none)" when it is empty. The ${arr[@]+...} form is what makes an empty array
# expand to nothing under `set -u` instead of tripping the unbound-variable check.
print_list() {
    local title="$1"
    shift
    echo "$title"
    if [ "$#" -eq 0 ]; then
        echo "  (none)"
    else
        local entry
        for entry in "$@"; do
            echo "  $entry"
        done
    fi
    echo
}

print_list "Real devices (usable):" ${hardware_ready[@]+"${hardware_ready[@]}"}
print_list "Your testing emulator '$RUN_AVD' (usable):" ${emulator_single[@]+"${emulator_single[@]}"}
print_list "Pool emulators (smoke tests; NOT a run target):" ${emulator_pool[@]+"${emulator_pool[@]}"}
print_list "Other emulators (NOT a run target):" ${emulator_other[@]+"${emulator_other[@]}"}
print_list "Attached but not usable (fix these to use them):" ${not_ready[@]+"${not_ready[@]}"}

# The choice a run makes, by the same rule as run-android.sh: an explicit PHOTOSPHERE_ANDROID_TARGET
# wins; otherwise a real device wins over the emulator; more than one real device is ambiguous and
# must be chosen; with no real device it uses the running RUN_AVD emulator, or starts one.
echo "What 'bun run and50' would do:"
if [ -n "${PHOTOSPHERE_ANDROID_TARGET:-}" ]; then
    echo "  Deploy to PHOTOSPHERE_ANDROID_TARGET=$PHOTOSPHERE_ANDROID_TARGET (overrides auto-selection)."
elif [ "${#hardware_ready[@]}" -gt 1 ]; then
    echo "  Refuse to guess: more than one real device attached. Choose one with:"
    for serial in "${hardware_ready[@]}"; do
        echo "    PHOTOSPHERE_ANDROID_TARGET=$serial bun run and50"
    done
elif [ "${#hardware_ready[@]}" -eq 1 ]; then
    echo "  Deploy to the real device ${hardware_ready[0]} (a plugged-in device wins over the emulator)."
elif [ "${#emulator_single[@]}" -ge 1 ]; then
    echo "  Deploy to your running testing emulator ${emulator_single[0]%% *}."
else
    echo "  Start the '$RUN_AVD' emulator (creating its AVD if missing) and deploy to it."
fi
