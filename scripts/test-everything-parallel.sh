#!/usr/bin/env bash
# Runs the project's checks all at once, stops the moment any of them fails, and reports each one
# separately.
#
# Sequentially the full set takes about eleven minutes on this machine; started together it takes about
# as long as the slowest one, which is roughly three and a half. That difference decides whether the
# pre-push hook is something people leave switched on or something they routinely bypass with
# --no-verify, and a gate that gets bypassed is worse than no gate at all.
#
# It fails fast: as soon as one script fails, the rest are killed rather than left to finish. There is
# no point waiting three more minutes for an answer that is already "no", and one failure is enough to
# stop a commit or a push. The trade is that a run reports the first failure rather than all of them,
# so a second failure elsewhere only shows up once the first is fixed.
#
# Called with no arguments it runs the whole set for the host platform. Called with script names it
# runs exactly those, which is how .githooks/pre-commit asks for just the two cheap ones.
#
# Every script's output is captured to its own file, and the ones that failed are printed in full at
# the end along with the command to re-run. Nothing is fixed, staged or committed here.
#
# Usage:
#   bun run test:everything               # the full set for this platform
#   bun run tev                           # the same thing, shorter
#   bun run test:everything compile test  # just those two, still in parallel
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_DIR"

# The mobile suites are chosen by host platform: the Android ones need an attached device or emulator,
# the iOS ones need a simulator, and neither toolchain exists on the other platform.
case "$(uname -s)" in
    Darwin)
        PLATFORM_SCRIPTS=(test:ios test:ios:unit)
        ;;
    *)
        PLATFORM_SCRIPTS=(test:and test:and:unit)
        ;;
esac

if [ "$#" -gt 0 ]; then
    SCRIPTS=("$@")
else
    SCRIPTS=(compile test test:cli test:electron "${PLATFORM_SCRIPTS[@]}")
fi

# Scripts that must not run at the same time as each other, one group per line, because they are not
# actually independent:
#
#   test:and and test:and:unit both run `bun run sync` (a Capacitor asset copy) and then Gradle against
#   the same apps/android-frontend/android project. Run together they are two builds writing one project
#   directory, which is a race on the generated assets and on Gradle's own state rather than parallel
#   work. test:ios and test:ios:unit are the same story for the Xcode project.
#
# Everything not named here runs fully in parallel. The cost of serialising a group is small: the native
# unit tests take about nine seconds against the smoke suite's two and a half minutes, so the group is
# still bounded by the suite it was already bounded by.
SERIAL_GROUPS=(
    "test:and:unit test:and"
    "test:ios:unit test:ios"
)

# Builds the lanes to run: each lane is a space-separated list of scripts run one after another, and the
# lanes themselves run in parallel. A serial group becomes one lane, in the order given above; every
# other requested script becomes a lane of its own.
build_lanes() {
    local remaining=" ${SCRIPTS[*]} "
    local group lane script

    for group in "${SERIAL_GROUPS[@]}"; do
        lane=""
        for script in $group; do
            case "$remaining" in
                *" $script "*)
                    lane="${lane:+$lane }$script"
                    remaining="${remaining/ $script / }"
                    ;;
            esac
        done
        if [ -n "$lane" ]; then
            LANES+=("$lane")
        fi
    done

    for script in $remaining; do
        LANES+=("$script")
    done
}

LOG_DIR="$(mktemp -d)"

# Pids of the lanes still believed to be running, in the same order as SCRIPTS.
LANE_PIDS=()

# Kills a process and everything it started. Killing only the lane's own pid would orphan the real work
# (bun, Gradle, an emulator driver), which would then keep running after this script had exited.
kill_tree() {
    local pid="$1"
    local child
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        kill_tree "$child"
    done
    kill -TERM "$pid" 2>/dev/null || true
}

# Kills every lane that is still running.
kill_remaining_lanes() {
    local pid
    for pid in "${LANE_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill_tree "$pid"
        fi
    done
}

cleanup() {
    kill_remaining_lanes
    rm -rf "$LOG_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Turns a script name into something usable as a filename, since the names contain colons.
log_name_for() {
    printf '%s' "$1" | tr ':' '-'
}

# Runs one script, writing its output and its exit code beside each other so the caller can report
# both, and returning that code so a waiting caller sees the failure too.
run_script() {
    local script="$1"
    local log_name code
    log_name="$(log_name_for "$script")"
    if command -v mise >/dev/null 2>&1; then
        mise exec -- bun run "$script" > "$LOG_DIR/$log_name.log" 2>&1 < /dev/null
    else
        bun run "$script" > "$LOG_DIR/$log_name.log" 2>&1 < /dev/null
    fi
    code=$?
    echo "$code" > "$LOG_DIR/$log_name.exit"
    return "$code"
}

# Runs one lane's scripts one after another, stopping at the first failure so the rest of that lane is
# left unrun and reported as such.
run_lane() {
    local lane="$1"
    local script
    for script in $lane; do
        if ! run_script "$script"; then
            return 1
        fi
    done
}

# Prints the exit code recorded for a script, or nothing when it has not finished.
recorded_exit_for() {
    local log_name
    log_name="$(log_name_for "$1")"
    if [ -f "$LOG_DIR/$log_name.exit" ]; then
        cat "$LOG_DIR/$log_name.exit"
    fi
}

LANES=()
build_lanes

# Refuses the whole run when an Android suite is asked for and no emulator is on the LAN bridge.
#
# The suite checks this for itself and fails in seconds, but by then the other lanes have started, so a
# pool that is down costs a compile and a unit run before anything says why, and their results are
# thrown away when the suite reports. Checking here means the run stops before any of that begins.
#
# Only the same condition the suite already requires is checked, and only when an Android suite is in
# the set: attached devices whose wlan0 carries a 192.168.55.x address. Nothing is started, stopped or
# repaired here; a pool that is down is reported and left exactly as it is.
require_android_emulator() {
    local script wanted="" serial healthy=0

    for script in "${SCRIPTS[@]}"; do
        case "$script" in
            test:and|test:and:unit) wanted="yes" ;;
        esac
    done
    if [ -z "$wanted" ]; then
        return 0
    fi
    if ! command -v adb >/dev/null 2>&1; then
        return 0
    fi

    for serial in $(adb devices 2>/dev/null | awk 'NR > 1 && $2 == "device" { print $1 }'); do
        if timeout 8 adb -s "$serial" shell ip addr show wlan0 </dev/null 2>/dev/null | grep -q 'inet 192\.168\.55\.'; then
            healthy=$((healthy + 1))
        fi
    done

    if [ "$healthy" -eq 0 ]; then
        echo "No emulator is on the LAN bridge, so the Android suites cannot run." >&2
        echo "Nothing has been started: the whole set is refused rather than run against a pool that is down." >&2
        echo "Check it with 'bun run emu:and:status', watch it with 'bun run emu:and:health'." >&2
        exit 1
    fi
}

require_android_emulator

echo "Running ${#SCRIPTS[@]} script(s) across ${#LANES[@]} parallel lane(s):"
for lane in "${LANES[@]}"; do
    case "$lane" in
        *" "*)
            echo "  $lane   (in this order, they share a build directory)"
            ;;
        *)
            echo "  $lane"
            ;;
    esac
done
echo "Stopping early if any of them fails."
echo ""

for lane in "${LANES[@]}"; do
    run_lane "$lane" &
    LANE_PIDS+=("$!")
done

# Waits for the lanes, returning as soon as one has failed rather than when all have finished.
#
# Polls the recorded exit codes rather than using `wait -n`, which would report the next lane to finish
# directly but only exists in bash 4.3 and later. macOS still ships bash 3.2, and these hooks have to
# work there.
first_failure=""
while true; do
    finished=0
    for script in "${SCRIPTS[@]}"; do
        code="$(recorded_exit_for "$script")"
        if [ -n "$code" ]; then
            finished=$((finished + 1))
            if [ "$code" != "0" ] && [ -z "$first_failure" ]; then
                first_failure="$script"
            fi
        fi
    done
    if [ -n "$first_failure" ]; then
        break
    fi
    if [ "$finished" -eq "${#SCRIPTS[@]}" ]; then
        break
    fi
    sleep 1
done

cancelled=()
if [ -n "$first_failure" ]; then
    for script in "${SCRIPTS[@]}"; do
        if [ -z "$(recorded_exit_for "$script")" ]; then
            cancelled+=("$script")
        fi
    done
    kill_remaining_lanes
fi

wait 2>/dev/null

failed=()

# Reported lane by lane rather than in the order the scripts were requested, so a lane's failure appears
# above the scripts that were skipped because of it rather than below them.
echo "Results:"
for script in $(printf '%s\n' "${LANES[@]}" | tr ' ' '\n'); do
    code="$(recorded_exit_for "$script")"
    if [ -z "$code" ]; then
        printf '  ....  bun run %s (cancelled, another script failed first)\n' "$script"
    elif [ "$code" = "0" ]; then
        printf '  PASS  bun run %s\n' "$script"
    else
        printf '  FAIL  bun run %s (exit %s)\n' "$script" "$code"
        failed+=("$script")
    fi
done

if [ "${#failed[@]}" -eq 0 ] && [ "${#cancelled[@]}" -eq 0 ]; then
    echo ""
    echo "All ${#SCRIPTS[@]} script(s) passed."
    exit 0
fi

for script in "${failed[@]}"; do
    log_name="$(log_name_for "$script")"
    echo "" >&2
    echo "========================================================================" >&2
    echo "Output of the failed 'bun run $script'" >&2
    echo "========================================================================" >&2
    cat "$LOG_DIR/$log_name.log" >&2
done

echo "" >&2
if [ "${#failed[@]}" -gt 0 ]; then
    echo "Failed:" >&2
    for script in "${failed[@]}"; do
        echo "    bun run $script" >&2
    done
fi
if [ "${#cancelled[@]}" -gt 0 ]; then
    echo "" >&2
    echo "Stopped before finishing, so their result is unknown:" >&2
    for script in "${cancelled[@]}"; do
        echo "    bun run $script" >&2
    done
fi
echo "" >&2
echo "Fix the failure above, then run the whole set again." >&2

exit 1
