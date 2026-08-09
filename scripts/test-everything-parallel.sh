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
# Called with no arguments it asks what-changed which targets are affected and runs only those. A
# docs-only change runs nothing at all. Called with script names it runs exactly those, ungated,
# because the caller has already decided. --force skips the question and runs the whole set for the
# host platform.
#
# what-changed only reports; it runs nothing itself. This script is what turns its answer into a run:
#
#   1. Ask `what-changed targets`, which prints one name per line and nothing when nothing changed.
#   2. Run those, all at once.
#
# Nothing here records a baseline. Each script in package.json captures its own target on success, so
# `bun run test:cli` alone marks test:cli as up to date whether it was run from here or by hand. That
# is why a script's capture is chained with && : a failing suite never reaches it, so a broken tree is
# never marked as tested, and one suite passing never marks another as passed.
#
# what-changed must be on PATH: https://github.com/ashleydavis/what-changed/releases
#
# Every script's output is captured to its own file, and the ones that failed are printed in full at
# the end along with the command to re-run. Nothing is fixed, staged or committed here.
#
# Usage:
#   bun run test:everything               # only what changed, for this platform
#   bun run tev                           # the same thing, shorter
#   bun run tev -- --force                # the whole set, changed or not
#   bun run tev -- --plan                 # print the decision, run nothing
#   bun run test:everything compile test  # just those two, ungated, still in parallel
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

FORCE=false
PLAN_ONLY=false
NAMED_SCRIPTS=()

for ARGUMENT in "$@"; do
    case "$ARGUMENT" in
        --force)
            FORCE=true
            ;;
        --plan)
            PLAN_ONLY=true
            ;;
        --*)
            echo "Unknown option \"$ARGUMENT\". Known options: --force, --plan." >&2
            exit 1
            ;;
        *)
            NAMED_SCRIPTS+=("$ARGUMENT")
            ;;
    esac
done


if [ "${#NAMED_SCRIPTS[@]}" -gt 0 ]; then
    SCRIPTS=("${NAMED_SCRIPTS[@]}")
elif [ "$FORCE" = true ]; then
    SCRIPTS=(
        compile
        test
        test:cli
        test:cli:encrypted
        test:cli:lan-share
        test:cli:sync
        test:cli:write-lock
        test:cli:hash-cache
        test:electron
        test:lan-share:cli-desktop
        test:harness
        "${PLATFORM_SCRIPTS[@]}"
    )
else
    if ! command -v what-changed >/dev/null 2>&1; then
        echo "what-changed is not on PATH." >&2
        echo "Get it from https://github.com/ashleydavis/what-changed/releases" >&2
        echo "Or pass --force to run the whole set without it." >&2
        exit 1
    fi

    SCRIPTS=()
    while IFS= read -r LINE; do
        if [ -n "$LINE" ]; then
            SCRIPTS+=("$LINE")
        fi
    done <<< "$(what-changed targets)"

    if [ "${#SCRIPTS[@]}" -eq 0 ]; then
        echo "Nothing to run: nothing has changed since the last passing run."
        echo "Use --force to run everything anyway."
        exit 0
    fi
fi

if [ "$PLAN_ONLY" = true ]; then
    echo "Would run: ${SCRIPTS[*]}"
    echo "--plan given, running nothing."
    exit 0
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

# Where each script's last successful duration is remembered, one file per script holding its seconds.
#
# Git-ignored and machine-local on purpose: it is a measurement of THIS machine, and an emulator here
# is not an emulator on a runner. It carries no meaning off this computer and nothing reads it but the
# estimate printed below.
DURATION_CACHE_DIR="$REPO_DIR/.test-durations"

# Prints the last recorded duration in seconds for a script, or nothing when it has never been timed.
recorded_duration_for() {
    local file="$DURATION_CACHE_DIR/$(log_name_for "$1")"
    if [ -f "$file" ]; then
        cat "$file" 2>/dev/null
    fi
}

# Records how long a script took, so the next run can say what to expect.
#
# Only a passing run is recorded. A failure usually stops early, so its duration says how long the
# suite took to break rather than how long it takes, and keeping it would make the estimate drift
# downwards every time something broke.
record_duration_for() {
    local script="$1"
    local seconds="$2"
    mkdir -p "$DURATION_CACHE_DIR"
    printf '%s\n' "$seconds" > "$DURATION_CACHE_DIR/$(log_name_for "$script")"
}

# Formats a count of seconds as m:ss, or seconds alone when it is under a minute.
format_seconds() {
    local total="$1"
    if [ "$total" -ge 60 ]; then
        printf '%dm %02ds' "$((total / 60))" "$((total % 60))"
    else
        printf '%ds' "$total"
    fi
}

# Runs one script, writing its output and its exit code beside each other so the caller can report
# both, and returning that code so a waiting caller sees the failure too.
run_script() {
    local script="$1"
    local log_name code started elapsed
    log_name="$(log_name_for "$script")"
    started=$SECONDS
    if command -v mise >/dev/null 2>&1; then
        mise exec -- bun run "$script" > "$LOG_DIR/$log_name.log" 2>&1 < /dev/null
    else
        bun run "$script" > "$LOG_DIR/$log_name.log" 2>&1 < /dev/null
    fi
    code=$?
    elapsed=$((SECONDS - started))
    echo "$code" > "$LOG_DIR/$log_name.exit"
    echo "$elapsed" > "$LOG_DIR/$log_name.seconds"
    if [ "$code" = "0" ]; then
        record_duration_for "$script" "$elapsed"
    fi
    return "$code"
}

# Prints the seconds a script took in this run, or nothing when it never finished.
elapsed_for() {
    local file="$LOG_DIR/$(log_name_for "$1").seconds"
    if [ -f "$file" ]; then
        cat "$file" 2>/dev/null
    fi
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

# Builds the desktop bundle once, for the whole run, when a suite that needs it is in the set.
#
# Both desktop suites bundle for themselves so that each works when run on its own, and both write the
# same directories: `bun run bundle` empties apps/desktop/bundle/frontend (vite's emptyOutDir) and
# rewrites apps/desktop/bundle. Started together that is one suite deleting the renderer the other is
# about to launch Electron against.
#
# Keeping the two suites in one lane fixed it and cost the run the shorter suite's whole runtime, about
# a minute, for a build that takes five seconds. Building it here instead, before any lane starts, costs
# five seconds once: PHOTOSPHERE_SKIP_DESKTOP_BUNDLE tells the suites it is already done, so they skip
# their own build and run at the same time as each other.
bundle_desktop_once() {
    local script wanted=""

    for script in "${SCRIPTS[@]}"; do
        case "$script" in
            test:electron|test:lan-share:cli-desktop) wanted="yes" ;;
        esac
    done
    if [ -z "$wanted" ]; then
        return 0
    fi

    local bundle_status=0
    echo "Bundling the desktop app once for this run..."
    if command -v mise >/dev/null 2>&1; then
        mise exec -- bun run bundle || bundle_status=$?
    else
        bun run bundle || bundle_status=$?
    fi

    if [ "$bundle_status" -ne 0 ]; then
        echo "The desktop bundle failed (exit $bundle_status), so nothing has been started." >&2
        exit 1
    fi

    export PHOTOSPHERE_SKIP_DESKTOP_BUNDLE=1
}

bundle_desktop_once

RUN_STARTED=$SECONDS

# Width of the lane-name column, so the estimates line up under each other rather than sitting at a
# different place on every row. Measured from the longest lane name actually being run.
lane_name_width=0
for lane in "${LANES[@]}"; do
    if [ "${#lane}" -gt "$lane_name_width" ]; then
        lane_name_width="${#lane}"
    fi
done

echo "Running ${#SCRIPTS[@]} script(s) across ${#LANES[@]} parallel lane(s):"
for lane in "${LANES[@]}"; do
    # The expected time is the sum of the lane's scripts, since a lane runs its scripts one after
    # another. A script that has never passed here has nothing to expect, and says so rather than
    # guessing at a number.
    lane_expected=0
    lane_unknown=""
    for script in $lane; do
        script_expected="$(recorded_duration_for "$script")"
        if [ -n "$script_expected" ]; then
            lane_expected=$((lane_expected + script_expected))
        else
            lane_unknown="yes"
        fi
    done

    # The tilde marks the number as an estimate rather than a measurement, which is what tells it
    # apart from the real durations printed in the results at the end.
    if [ -n "$lane_unknown" ]; then
        lane_estimate="not timed yet"
    else
        lane_estimate="$(format_seconds "$lane_expected") ~"
    fi

    case "$lane" in
        *" "*)
            printf '  %-*s  %s   (in this order, they share a build directory)\n' \
                "$lane_name_width" "$lane" "$lane_estimate"
            ;;
        *)
            printf '  %-*s  %s\n' "$lane_name_width" "$lane" "$lane_estimate"
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
RUN_ELAPSED=$((SECONDS - RUN_STARTED))

# Same column width as the lane listing above, so the durations here sit under the estimates there.
script_name_width=0
for script in $(printf '%s\n' "${LANES[@]}" | tr ' ' '\n'); do
    if [ "${#script}" -gt "$script_name_width" ]; then
        script_name_width="${#script}"
    fi
done

echo "Results:"
for script in $(printf '%s\n' "${LANES[@]}" | tr ' ' '\n'); do
    code="$(recorded_exit_for "$script")"
    took="$(elapsed_for "$script")"
    if [ -n "$took" ]; then
        took_text="$(format_seconds "$took")"
    else
        took_text=""
    fi
    if [ -z "$code" ]; then
        printf '  ....  bun run %-*s  cancelled, another script failed first\n' "$script_name_width" "$script"
    elif [ "$code" = "0" ]; then
        printf '  PASS  bun run %-*s  %s\n' "$script_name_width" "$script" "$took_text"
    else
        printf '  FAIL  bun run %-*s  %s   exit %s\n' "$script_name_width" "$script" "$took_text" "$code"
        failed+=("$script")
    fi
done

# The wall clock, and beside it what the same scripts would have cost run one after another. The two
# differ because the lanes run at the same time, and the gap is what the parallelism is worth.
sequential_total=0
for script in $(printf '%s\n' "${LANES[@]}" | tr ' ' '\n'); do
    took="$(elapsed_for "$script")"
    if [ -n "$took" ]; then
        sequential_total=$((sequential_total + took))
    fi
done
echo ""
printf 'Total: %s (%s if run one after another)\n' \
    "$(format_seconds "$RUN_ELAPSED")" "$(format_seconds "$sequential_total")"

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
