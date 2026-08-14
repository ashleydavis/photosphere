#!/usr/bin/env bash
#
# usage-begin
# Finds test scripts that break each other when they run at the same time.
#
# `bun run test:everything` starts the suites concurrently, so any two of them that touch the same
# file, port, directory, lock or device can fail each other in ways that never show up when a suite is
# run on its own. That is a different failure class from ordinary flakiness: the suite is not
# unreliable in itself, it is unreliable in company. Nothing else detects it, and the two conflicts
# already known (the Android pair and the iOS pair kept apart by SERIAL_GROUPS in
# scripts/test-everything-parallel.sh) were found by being bitten.
#
# This runs every selected script alone first, to establish that it is sound on its own, then runs
# every combination of two of them concurrently, and reports only the failures that appear in company
# and not alone.
#
# Self-pairs are included: a script is checked against a second copy of itself. Nothing in
# test:everything runs one suite twice at once, but two worktrees, two developers on one machine, or a
# rerun started before the last one finished all do. A self-pair is also the cheapest way to surface a
# fixed path or a fixed port, because a suite that hardcodes one always collides with a second copy of
# itself.
#
# This is a companion to `bun run find-flakey-tests`, not a replacement: that one proves a suite is
# sound alone, this one proves it is sound in company, and the second is only meaningful once the
# first has passed. When a combination comes back `inconclusive`, run that one first.
#
# Usage:
#
#   bun run test:parallel
#       Check every suite this machine can run, including the mobile ones. With a terminal attached
#       This is the normal way to run it by hand, and it is slow: it needs the emulator pool already
#       up, and every suite it names takes minutes.
#
#   bun run test:parallel -- --scripts "test test:cli"
#       Check just those two, which is 3 combinations (2 pairs plus 2 self-pairs). This is how to get
#       a quick answer without paying for the mobile suites.
#
#   bun run test:parallel -- --scripts "test:and test:and:unit"
#       The positive control: SERIAL_GROUPS in scripts/test-everything-parallel.sh already keeps this
#       pair apart because they share a build directory, so a run that does not report them as
#       interference means this check is not working.
#
#   bun run test:parallel -- --help
#
# Options:
#
#   --scripts "A B C"
#                 check exactly these scripts, space separated, instead of everything this machine can
#                 run. Any script in the root package.json may be named, including ones outside the
#                 default set such as compile, test:and:unit and test:ios:unit. Naming scripts turns
#                 off the mobile detection below: you get precisely what you asked for.
#
#   --command TEMPLATE
#                 run each name through this command instead of `bun run <name>`. `{}` in the template
#                 is replaced by the name. This is the escape hatch for driving the check against
#                 commands with known outcomes rather than against the real suites. Script names are
#                 not checked against package.json when it is given.
#
#   --help        print this usage and exit.
#
# The default set is test, test:cli and test:electron plus the mobile suites this machine can actually
# run. test:ios is included only on macOS. test:and is included on any platform where the Android
# tooling is installed and `bun run emu:and:status` reports a ready device, and is dropped with a
# printed reason otherwise, because a suite that cannot run would fail every combination it is in for
# a reason that is not interference. A dropped suite is reported at the top of the run and again in
# the summary, with the count of combinations that went unchecked, so a reduced run can never be
# mistaken for a clean one.
#
# Every script is run once on its own and every combination is run once. A conflict that only shows up
# on some runs will therefore be missed: this says whether a conflict is there, not how often it
# happens. `bun run find-flakey-tests` is the tool for the second question.
#
# Output: everything is written under tmp/parallel-check/<timestamp>/ in the repo (gitignored), one
# log per side, plus a report.txt when interference is found. The paths are printed as the last lines
# of stdout. Nothing here ever deletes or overwrites a path.
#
# Exit status:
#
#   0  no interference found.
#   1  interference found: two scripts that each pass alone fail when run together.
#   2  bad usage.
#   3  too many consecutive Bun crashes made the result meaningless.
#   4  the emulator pool degraded during the run, so it was abandoned.
#   5  no interference found, but at least one script was unstable on its own, so the combinations it
#      is in prove nothing. Run `bun run find-flakey-tests -- --script <name>` on that script first.
# usage-end
#
set -uo pipefail

# Repo root, resolved from this script's location so it runs from any working directory.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Every suite is started from the repository root, whatever directory this was invoked from, because
# that is where the bun scripts expect to be run from.
cd "$ROOT" || exit 2

# Text that identifies a crash of the Bun runtime itself, as opposed to a test failure. Matched
# against a run's whole output.
BUN_CRASH_PATTERN="Bun has crashed|panic: |terminated by signal SIG(ILL|SEGV|BUS|ABRT)|Segmentation fault"

# Records the state of the machine at the moment of a failure. Some of the failures this check finds
# are nothing to do with the code: the kernel's out-of-memory killer taking a suite, or an emulator
# vanishing mid-test. Neither is visible in the suite's own output, and a pair reported as interfering
# when really the machine gave up is the most expensive wrong answer this can give.
capture_machine_state() {
    echo "--- machine state at failure ---"
    echo "date: $(date -Is)"

    if command -v free >/dev/null 2>&1; then
        echo "memory:"
        free -h 2>&1 | sed 's/^/  /'
    fi

    if command -v adb >/dev/null 2>&1; then
        echo "attached devices:"
        adb devices 2>&1 | sed 's/^/  /'
    fi

    # An out-of-memory kill explains a whole suite failing at once and leaves no trace in the suite's
    # own logs, so it is worth looking for explicitly.
    if command -v journalctl >/dev/null 2>&1; then
        local oom_lines
        oom_lines="$(journalctl -k --since "1 hour ago" --no-pager 2>/dev/null | grep -iE "oom-kill|Out of memory: Killed" | tail -5)"
        if [ -n "$oom_lines" ]; then
            echo "kernel out-of-memory kills in the last hour:"
            echo "$oom_lines" | sed 's/^/  /'
        else
            echo "kernel out-of-memory kills in the last hour: none"
        fi
    fi
}

# Pulls the interesting lines out of a failed run's output: which parallel lane failed, which named
# tests failed, and where their logs are. The suites print these in a stable form, so a failure can
# be summarised without anyone having to read thousands of lines of build output.
summarise_failure() {
    local log_file="$1"

    echo "--- failing lanes ---"
    grep -E "^\s+FAIL\s+bun run|error: script .* exited with code" "$log_file" | sed 's/^/  /' || echo "  (none matched)"

    echo
    echo "--- failing tests ---"
    # Not anchored to the start of the line, because the suites colour these and the line therefore
    # begins with an escape sequence rather than the word.
    grep -aE "FAIL.*\(log:|tests? failed" "$log_file" | sed 's/^/  /' || echo "  (none matched)"

    echo
    echo "--- last 60 lines of the run ---"
    tail -60 "$log_file" | sed 's/^/  /'
}

# Copies the per-test log files the mobile and desktop smoke suites write under their own tmp dirs.
# The runners clear those before each test, so without this they are gone the moment the next
# combination starts, and they are the evidence for why a side failed.
snapshot_suite_logs() {
    local destination="$1"
    local found=0
    local log_file relative_path target_dir

    while IFS= read -r log_file; do
        relative_path="${log_file#"$ROOT"/}"
        target_dir="$destination/$(dirname "$relative_path")"
        mkdir -p "$target_dir"
        cp "$log_file" "$target_dir/"
        found=1
    done < <(find "$ROOT/apps/smoke-tests/tests" "$ROOT/apps/desktop/smoke-tests" -path '*/tmp/*' -name '*.log' -type f 2>/dev/null)

    return $((1 - found))
}

#
# Reports whether every attached Android emulator is still answering, printing a reason and returning
# non-zero for the first one that is not. Says nothing about how many devices there are, which is the
# caller's business.
#
# This only ever reads. It does not start, stop, reconnect or otherwise touch a device: recovering the
# pool is a person's job.
#
# Usage: check_devices_responding
#
check_devices_responding() {
    local serial

    for serial in $(adb devices 2>/dev/null | grep "device$" | cut -f1); do
        if ! timeout 30 adb -s "$serial" shell "cmd package list packages" 2>/dev/null | grep -q "^package:"; then
            echo "$serial is attached but its package manager service is not answering" >&2
            return 1
        fi

        # Whether the guest can still reach the host. Every mobile test depends on this: the app talks
        # to the host's control bridge over the LAN bridge, so a device that cannot reach the host
        # fails every test assigned to it while adb still reports it as present and healthy.
        if ! timeout 30 adb -s "$serial" shell "ping -c 1 -W 2 192.168.55.1" >/dev/null 2>&1; then
            echo "$serial is attached but cannot reach the host at 192.168.55.1" >&2
            return 1
        fi
    done

    return 0
}

#
# Reports whether the pool is still the one this run started with: the same number of devices, every
# one of them answering. Prints a reason and returns non-zero when it is not.
#
# Usage: check_devices_healthy <expected_count>
#
check_devices_healthy() {
    local expected="$1"
    local attached

    # Counted twice, a second apart, and only a count that is still wrong the second time is treated
    # as the pool having changed. `adb devices` lists a device as "offline" rather than "device"
    # while it is busy, and an emulator sharing a loaded machine goes briefly offline without having
    # gone anywhere: it was answering again a moment later. A single sample cannot tell that from an
    # emulator that has died, and the difference matters, because this reading stops the whole run.
    #
    # Measured: a run stopped here with 4 of 5 while the pool monitor, sampling every minute either
    # side of it, recorded 5 of 5 healthy throughout and memory at 43 to 50 percent, so nothing had
    # died and nothing was repaired. The same single-sample trap is recorded in
    # docs/flaky-tests-registry.md as LAN-BRIDGE-PROBE-SINGLE-SAMPLE.
    #
    # This does not soften the check against a real loss: an emulator that is gone is still gone a
    # second later, and every other reason the pool can be unhealthy is untouched below.
    attached="$(adb devices 2>/dev/null | grep -c "device$")"
    if [ "$attached" -ne "$expected" ]; then
        sleep 1
        attached="$(adb devices 2>/dev/null | grep -c "device$")"
        if [ "$attached" -ne "$expected" ]; then
            echo "device count changed: started with $expected, now $attached (twice, a second apart)" >&2
            return 1
        fi
    fi

    check_devices_responding
}

#
# Prints how many pool emulators are on the LAN bridge, and 0 when none is or the check cannot run.
#
# This is the count that matters after a pair including test:and, and it is not the same as the
# attached device count check_devices_healthy uses: an emulator killed for using too much memory
# disappears from both, but one that is up and off the bridge is still attached and is useless to
# every mobile test. Read-only, as android-pool-status.sh is.
#
pool_bridge_count() {
    local output
    output="$(bash "$ROOT/scripts/android-pool-status.sh" 2>/dev/null || true)"
    # The summary line is "pool up: N of M pool emulator(s) on the LAN bridge" or "pool up: N pool
    # emulator(s) on the LAN bridge", and the first number in it is the count on the bridge.
    printf '%s\n' "$output" | sed 's/\x1b\[[0-9;]*m//g' | awk '/on the LAN bridge/ { print $3; exit }' | grep -E '^[0-9]+$' || echo 0
}

# How many pool emulators were on the LAN bridge when the sweep started, and whether that reading was
# taken at all. The sweep pairs test:and against every other suite, which is the deliberate stacking
# that killed two emulators, so a sweep that has cost the pool an emulator is stopped rather than
# carried on: every later pair would be measuring a smaller pool, and a pair reported as interfering
# on those results names the wrong thing.
POOL_BRIDGE_COUNT_AT_START=0

# The desktop-side scripts checked when none are named. The mobile suites this machine can run are
# added to these, which is why a default run is slow.
DEFAULT_SCRIPTS="test test:cli test:electron"

# The scripts to check, as given by --scripts. Empty until resolved.
REQUESTED_SCRIPTS=""

# Whether --scripts was given. Naming scripts means exactly those and no mobile detection.
SCRIPTS_GIVEN=0

# The command template from --command, with {} standing for the script name. Empty means the scripts
# are real bun scripts and are run as such.
COMMAND_TEMPLATE=""

# How many Bun runtime crashes in a row are tolerated before giving up. One crash is bad luck and is
# retried; a run of them means something is genuinely broken and continuing would hide it.
BUN_CRASH_RETRIES=5

# Prints the usage block at the top of this file, so there is one copy of it rather than two.
print_usage() {
    # Delimited by sentinel lines rather than by hardcoded line numbers. The equivalent in
    # scripts/find-flakey-tests.sh selects lines 3 to 89, and that range went stale once and silently
    # dropped an entire option out of the help without anything noticing.
    sed -n '/^# usage-begin$/,/^# usage-end$/p' "${BASH_SOURCE[0]}" \
        | sed '1d;$d' \
        | sed 's/^# \{0,1\}//'
}

# Every option this script accepts, named in the message when an unknown one is given so the reply
# says what would have worked rather than only what did not.
OPTION_CHOICES="--scripts --command --help"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --scripts)
            REQUESTED_SCRIPTS="${2:-}"
            SCRIPTS_GIVEN=1
            shift 2
            ;;
        --command)
            COMMAND_TEMPLATE="${2:-}"
            shift 2
            ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        *)
            echo "check-parallel-tests: unknown option '$1'" >&2
            echo "check-parallel-tests: the options are: $OPTION_CHOICES" >&2
            echo "Try: bun run test:parallel -- --help" >&2
            exit 2
            ;;
    esac
done

if [ -z "$REQUESTED_SCRIPTS" ]; then
    REQUESTED_SCRIPTS="$DEFAULT_SCRIPTS"
fi

# Prints the command that runs one script. With --command the name is substituted into the template,
# which is how the harness test drives this against fixtures. Otherwise it is a bun script, run
# through mise when mise is present so the suites use the toolchain the project pins rather than
# whatever happens to be first on PATH. That is what scripts/find-flakey-tests.sh and both branches of
# run_script in scripts/test-everything-parallel.sh do.
command_for() {
    local script="$1"
    if [ -n "$COMMAND_TEMPLATE" ]; then
        printf '%s' "${COMMAND_TEMPLATE//\{\}/$script}"
    elif command -v mise >/dev/null 2>&1; then
        printf 'mise exec -- bun run %s' "$script"
    else
        printf 'bun run %s' "$script"
    fi
}

# Turns a script name into something usable inside a filename, since the names contain colons.
safe_name() {
    printf '%s' "$1" | tr ':' '-'
}

# Prints how to invoke jq, which is pinned in mise.toml and so may only be reachable through mise.
# Prints nothing when there is no way to reach it.
jq_command() {
    if command -v jq >/dev/null 2>&1; then
        printf 'jq'
    elif command -v mise >/dev/null 2>&1 && mise exec -- jq --version >/dev/null 2>&1; then
        printf 'mise exec -- jq'
    fi
}

# Rejects a script name that is not in the root package.json, naming the ones that are. Skipped
# entirely under --command, where the names are fixtures rather than bun scripts.
validate_script_names() {
    local jq available script
    jq="$(jq_command)"
    if [ -z "$jq" ]; then
        echo "check-parallel-tests: jq is needed to check the script names against package.json and was not found (it is pinned in mise.toml; try running this through mise)." >&2
        exit 2
    fi

    available="$($jq -r '.scripts | keys[]' "$ROOT/package.json" 2>/dev/null | tr '\n' ' ')"
    if [ -z "$available" ]; then
        echo "check-parallel-tests: could not read the script names out of $ROOT/package.json" >&2
        exit 2
    fi

    for script in $REQUESTED_SCRIPTS; do
        case " $available " in
            *" $script "*)
                ;;
            *)
                echo "check-parallel-tests: '$script' is not a script in package.json." >&2
                echo "check-parallel-tests: the scripts are: $available" >&2
                exit 2
                ;;
        esac
    done
}

if [ -z "$COMMAND_TEMPLATE" ]; then
    validate_script_names
fi

# Whether the Android tooling this machine would need to run test:and is installed. Probed rather than
# assumed from the platform, so a macOS machine with Android Studio checks both mobile suites.
android_tooling_present() {
    if command -v adb >/dev/null 2>&1; then
        return 0
    fi
    if [ -n "${ANDROID_HOME:-}" ] && [ -x "$ANDROID_HOME/platform-tools/adb" ]; then
        return 0
    fi
    if [ -n "${ANDROID_SDK_ROOT:-}" ] && [ -x "$ANDROID_SDK_ROOT/platform-tools/adb" ]; then
        return 0
    fi
    return 1
}

# The scripts actually being checked, after mobile detection.
SELECTED=()

# Reasons a requested suite was left out, printed at the top of the run and again in the summary so a
# reduced run can never be mistaken for a clean one.
SKIPPED_REASONS=()

for requested_script in $REQUESTED_SCRIPTS; do
    SELECTED+=("$requested_script")
done

# Adds the mobile suites this machine can actually run. Each one that cannot run is dropped with a
# printed reason rather than left in to fail every combination it appears in for a reason that has
# nothing to do with interference. Nothing here starts, stops or restarts an emulator: per
# apps/android-frontend/CLAUDE.md that is the human's job.
add_mobile_scripts() {
    local status_command

    if [ "$(uname -s)" = "Darwin" ]; then
        SELECTED+=("test:ios")
    else
        SKIPPED_REASONS+=("test:ios: not added, this is not macOS")
    fi

    if ! android_tooling_present; then
        SKIPPED_REASONS+=("test:and: not added, no adb on PATH or under \$ANDROID_HOME/\$ANDROID_SDK_ROOT")
        return
    fi

    if command -v mise >/dev/null 2>&1; then
        status_command="mise exec -- bun run emu:and:status"
    else
        status_command="bun run emu:and:status"
    fi

    if ! (cd "$ROOT" && bash -c "$status_command" >/dev/null 2>&1); then
        SKIPPED_REASONS+=("test:and: not added, 'bun run emu:and:status' does not report a ready device (the emulator pool is the human's to bring up)")
        return
    fi

    SELECTED+=("test:and")
}

# Naming scripts means exactly those. Otherwise the mobile suites this machine can run are part of the
# set, because a conflict between a mobile suite and a desktop one is exactly the kind this exists to
# find and leaving it out by default would hide it.
if [ "$SCRIPTS_GIVEN" -eq 0 ]; then
    add_mobile_scripts
fi

# Everything this session writes lives here. Under tmp/, which is gitignored, and stamped with the
# start time so a new session never writes over an older one's evidence.
SESSION_DIR="$ROOT/tmp/parallel-check/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$SESSION_DIR"

REPORT="$SESSION_DIR/report.txt"

# One row per combination, written as it is decided and read back by print_summary, which walks it once
# per verdict so every finding sorts above the rest. A file rather than an array so the rows survive as
# evidence beside the logs, and because associative arrays do not exist in the bash 3.2 macOS ships.
RESULTS="$SESSION_DIR/results.tsv"

# Consecutive Bun crashes, reset by any run that does not crash.
CONSECUTIVE_CRASHES=0

# Every Bun crash seen this session, reported at the end so none passes unnoticed.
CRASH_LIST=()

# Whether any interference was found. Every conflict counts: none is muted, not even the pairs
# SERIAL_GROUPS already keeps apart, because a known conflict is still a conflict and a check that
# hides some of them cannot be read at a glance.
FOUND_INTERFERENCE=0

# How many combinations could not be decided because a script was unstable on its own.
INCONCLUSIVE_COUNT=0

# Whether a report has been written yet, so the first finding creates report.txt and later ones append
# to it rather than overwriting the first one's evidence.
REPORT_STARTED=0

# Prints the path for one run's log. A run retried after a Bun crash gets its own path rather than
# writing over the crashed one it replaces, because nothing here may overwrite an existing file.
run_log_path() {
    local prefix="$1" try="$2"
    if [ "$try" -eq 1 ]; then
        printf '%s/%s.log' "$SESSION_DIR" "$prefix"
    else
        printf '%s/%s-retry%s.log' "$SESSION_DIR" "$prefix" "$try"
    fi
}

# Records a Bun crash and stops the whole run once too many have happened in a row. A crash of the
# runtime is not one suite breaking another, so counting it as a result would name an innocent pair.
note_crash() {
    local description="$1"
    CONSECUTIVE_CRASHES=$((CONSECUTIVE_CRASHES + 1))
    CRASH_LIST+=("$description")
    echo "    BUN CRASH, not counted, retrying (crash $CONSECUTIVE_CRASHES of $BUN_CRASH_RETRIES allowed in a row)"
    if [ "$CONSECUTIVE_CRASHES" -ge "$BUN_CRASH_RETRIES" ]; then
        echo
        echo "check-parallel-tests: $CONSECUTIVE_CRASHES Bun crashes in a row; stopping, because a result built on that many crashes would mean nothing."
        echo "Crash logs:"
        for crash_line in "${CRASH_LIST[@]}"; do
            echo "  $crash_line"
        done
        echo "LOGS=$SESSION_DIR"
        exit 3
    fi
}

# Whether a run's output is a crash of the Bun runtime rather than a test failure.
output_is_bun_crash() {
    grep -qE "$BUN_CRASH_PATTERN" "$1"
}

# Runs one script on its own, capturing its output and recording its exit code beside it, retrying
# rather than recording a result when the Bun runtime crashes.
#
# Usage: run_alone <script>
run_alone() {
    local script="$1"
    local prefix try log status
    prefix="alone-$(safe_name "$script")"
    try=1

    while true; do
        log="$(run_log_path "$prefix" "$try")"
        bash -c "$(command_for "$script")" > "$log" 2>&1 < /dev/null
        status=$?
        if [ "$status" -ne 0 ] && output_is_bun_crash "$log"; then
            note_crash "$script alone: $log"
            try=$((try + 1))
            continue
        fi
        break
    done

    CONSECUTIVE_CRASHES=0
    echo "$status" > "$SESSION_DIR/$prefix.exit"
    ALONE_LOG="$log"
    ALONE_STATUS="$status"
}

# Prints one script's baseline verdict, read from the exit code run_alone recorded: `clean` when it
# passed, `unstable-alone` when it did not. The alone phase always runs, so there is always something
# to read.
baseline_verdict() {
    local script="$1"
    local exit_file
    exit_file="$SESSION_DIR/alone-$(safe_name "$script").exit"

    if [ -f "$exit_file" ] && [ "$(cat "$exit_file")" != "0" ]; then
        echo "unstable-alone"
        return
    fi
    echo "clean"
}

# Runs every selected script on its own, once each, so a script that is broken or flaky right now can
# be told apart from one that is broken by a partner.
run_baseline_phase() {
    local script verdict

    echo "Phase 1 of 2: running each script on its own."
    for script in "${SELECTED[@]}"; do
        printf '  %s alone ... ' "$script"
        run_alone "$script"
        if [ "$ALONE_STATUS" -eq 0 ]; then
            echo "pass"
        else
            echo "FAIL (exit $ALONE_STATUS, $ALONE_LOG)"
        fi
        verdict="$(baseline_verdict "$script")"
        echo "  $script alone: $verdict"
    done
    echo
}

# Prints every unordered combination of two of the selected scripts, one per line, including the
# self-pairs. For n scripts that is n(n+1)/2 lines, not n(n-1)/2: a script paired with a second copy of
# itself is exactly what a second worktree or an overlapping rerun produces, and it is the cheapest way
# to surface a fixed path or a fixed port.
generate_pairs() {
    local outer inner
    for (( outer = 0; outer < ${#SELECTED[@]}; outer++ )); do
        for (( inner = outer; inner < ${#SELECTED[@]}; inner++ )); do
            echo "${SELECTED[$outer]} ${SELECTED[$inner]}"
        done
    done
}

# Runs both sides of one combination concurrently and records both exit codes.
#
# The two commands are worked out before either is started so the two `bash -c` calls follow each other
# as closely as possible: the setup phases are where fixed paths and fixed ports collide, so the sides
# have to overlap there rather than one finishing its setup before the other begins.
#
# The side number is part of every log's name, not only a self-pair's, so the two sides of `test` with
# `test` can never write the same path.
#
# Usage: run_pair <script_a> <script_b>
run_pair() {
    local script_a="$1" script_b="$2"
    local prefix try log_a log_b command_a command_b pid_a pid_b

    prefix="pair-$(safe_name "$script_a")-$(safe_name "$script_b")"
    command_a="$(command_for "$script_a")"
    command_b="$(command_for "$script_b")"
    try=1

    while true; do
        log_a="$(run_log_path "$prefix-side1" "$try")"
        log_b="$(run_log_path "$prefix-side2" "$try")"

        bash -c "$command_a" > "$log_a" 2>&1 < /dev/null &
        pid_a=$!
        bash -c "$command_b" > "$log_b" 2>&1 < /dev/null &
        pid_b=$!

        wait "$pid_a"
        PAIR_STATUS_A=$?
        wait "$pid_b"
        PAIR_STATUS_B=$?

        if { [ "$PAIR_STATUS_A" -ne 0 ] && output_is_bun_crash "$log_a"; } \
            || { [ "$PAIR_STATUS_B" -ne 0 ] && output_is_bun_crash "$log_b"; }; then
            note_crash "$script_a with $script_b: $log_a and $log_b"
            try=$((try + 1))
            continue
        fi
        break
    done

    CONSECUTIVE_CRASHES=0
    echo "$PAIR_STATUS_A" > "$SESSION_DIR/$prefix-side1.exit"
    echo "$PAIR_STATUS_B" > "$SESSION_DIR/$prefix-side2.exit"
    PAIR_LOG_A="$log_a"
    PAIR_LOG_B="$log_b"
}

# Decides what one combination's result means, given the baseline verdicts and whether either side
# failed when the two ran together. Exactly one of:
#
#   ok            both scripts are sound alone and both sides passed when they ran together.
#   interference  both scripts are sound alone and at least one side failed when they ran together.
#   inconclusive  at least one script failed on its own, so nothing the pair did proves anything.
#
# A self-pair is classified by the same rule as any other: a script that is clean alone and fails
# against a second copy of itself is interference, and the summary names it as a self-pair.
#
# Usage: classify_pair <script_a> <script_b> <either_side_failed>
classify_pair() {
    local script_a="$1" script_b="$2" either_failed="$3"
    local verdict_a verdict_b

    verdict_a="$(baseline_verdict "$script_a")"
    verdict_b="$(baseline_verdict "$script_b")"

    if [ "$verdict_a" = "unstable-alone" ] || [ "$verdict_b" = "unstable-alone" ]; then
        echo "inconclusive"
    elif [ "$either_failed" -eq 1 ]; then
        echo "interference"
    else
        echo "ok"
    fi
}

# Writes the evidence for one interference finding: what failed, the baseline verdicts that make the
# finding mean something, the useful part of a very long log, and the state of the machine, because a
# pair reported as interfering when really the out-of-memory killer took one side is the most expensive
# possible wrong answer here.
#
# Usage: write_report <script_a> <script_b> <failing_side> <status_a> <status_b> <failing_log>
write_report() {
    local script_a="$1" script_b="$2" failing_side="$3"
    local status_a="$4" status_b="$5" failing_log="$6"
    local block

    block="$(
        echo "check-parallel-tests interference report"
        echo "========================================"
        echo
        echo "combination:      $script_a with $script_b"
        if [ "$script_a" = "$script_b" ]; then
            echo "                  (a self-pair: one script against a second copy of itself)"
        fi
        echo "failing side:     $failing_side"
        echo "exit status:      side1 $status_a, side2 $status_b"
        echo "alone verdicts:   $script_a is $(baseline_verdict "$script_a"), $script_b is $(baseline_verdict "$script_b")"
        echo "session:          $SESSION_DIR"
        echo "failing side log: $failing_log"
        echo
        summarise_failure "$failing_log"
        echo
        capture_machine_state
    )"

    if [ "$REPORT_STARTED" -eq 0 ]; then
        echo "$block" > "$REPORT"
        REPORT_STARTED=1
    else
        {
            echo
            echo
            echo "$block"
        } >> "$REPORT"
    fi

    echo "$block"
    echo
}

# Runs every combination once and decides each one, writing a report and snapshotting the suite's own
# per-test logs the moment a finding appears, because the next combination overwrites those logs.
run_pair_phase() {
    local pair script_a script_b
    local either_failed failing_side failing_log
    local verdict snapshot_dir pool_bridge_count_now
    local pairs=()

    # The whole list is read up front rather than being streamed into the loop. Streaming it made the
    # run stop after the first combination whenever a mobile suite was selected: check_devices_healthy
    # shells out to adb, adb reads standard input, and it swallowed the rest of the list.
    while IFS= read -r pair; do
        pairs+=("$pair")
    done < <(generate_pairs)

    echo "Phase 2 of 2: running every combination."
    for pair in "${pairs[@]}"; do
        script_a="${pair% *}"
        script_b="${pair#* }"
        either_failed=0
        failing_side=""
        failing_log=""

        if [ "$DEVICE_COUNT_AT_START" -gt 0 ] && ! check_devices_healthy "$DEVICE_COUNT_AT_START"; then
            echo
            echo "check-parallel-tests: STOPPING at $script_a with $script_b because the emulator pool is no longer healthy."
            echo "Nothing here changed anything on any device. Restart the pool and run this again."
            echo "LOGS=$SESSION_DIR"
            exit 4
        fi

        printf '  %s with %s ... ' "$script_a" "$script_b"
        run_pair "$script_a" "$script_b"

        if [ "$PAIR_STATUS_A" -eq 0 ] && [ "$PAIR_STATUS_B" -eq 0 ]; then
            echo "both passed"
        else
            echo "FAIL (side1 exit $PAIR_STATUS_A, side2 exit $PAIR_STATUS_B)"
            either_failed=1
            if [ "$PAIR_STATUS_A" -ne 0 ]; then
                failing_side="side1 ($script_a)"
                failing_log="$PAIR_LOG_A"
            else
                failing_side="side2 ($script_b)"
                failing_log="$PAIR_LOG_B"
            fi

            if [ "$(classify_pair "$script_a" "$script_b" 1)" = "interference" ]; then
                write_report "$script_a" "$script_b" "$failing_side" \
                    "$PAIR_STATUS_A" "$PAIR_STATUS_B" "$failing_log"
                # Before the next combination starts, because the mobile and desktop suites clear
                # their per-test logs at the start of each run and those logs are the evidence.
                snapshot_dir="$SESSION_DIR/suite-logs-$(safe_name "$script_a")-$(safe_name "$script_b")"
                if snapshot_suite_logs "$snapshot_dir"; then
                    echo "suite logs:       $snapshot_dir" >> "$REPORT"
                fi
            fi
        fi

        # After the pair rather than before the next one, so the pair that cost the emulator is the
        # one named. Only for pairs that included test:and: the desktop suites cannot take an
        # emulator off the bridge, and a pool that lost one while they ran lost it to something else.
        if [ "$POOL_BRIDGE_COUNT_AT_START" -gt 0 ]; then
            case " $script_a $script_b " in
                *" test:and "*)
                    pool_bridge_count_now="$(pool_bridge_count)"
                    if [ "$pool_bridge_count_now" -lt "$POOL_BRIDGE_COUNT_AT_START" ]; then
                        echo
                        echo "check-parallel-tests: STOPPING after $script_a with $script_b: the pool has lost an emulator."
                        echo "  $POOL_BRIDGE_COUNT_AT_START pool emulator(s) were on the LAN bridge when this sweep started, $pool_bridge_count_now are now."
                        echo "  Every later pair would be measured against a smaller pool, so the results would be about the wrong thing."
                        echo "  Nothing here changed anything on any device. To put the pool back:"
                        echo "    bun run --filter=android-frontend emu:pool:repair"
                        echo "LOGS=$SESSION_DIR"
                        exit 4
                    fi
                    ;;
            esac
        fi

        verdict="$(classify_pair "$script_a" "$script_b" "$either_failed")"
        case "$verdict" in
            interference)
                FOUND_INTERFERENCE=1
                ;;
            inconclusive)
                INCONCLUSIVE_COUNT=$((INCONCLUSIVE_COUNT + 1))
                ;;
        esac

        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$verdict" "$script_a" "$script_b" "${failing_side:-none}" "${failing_log:-none}" >> "$RESULTS"
        echo "  $script_a with $script_b: $verdict"
    done
    echo
}

# Prints the table of combinations, every interference row first, then what could not be decided, then
# the rest, followed by everything that qualifies the verdict: the skipped suites, the combinations no
# answer could be given for, and any Bun crashes.
print_summary() {
    local verdict script_a script_b failing_side failing_log label reason crash_line
    local wanted selected_count skipped_count total_count missing_count

    echo "Summary"
    echo "======="
    echo
    printf '%-14s  %-40s  %-22s  %s\n' "VERDICT" "COMBINATION" "FAILING SIDE" "FIRST FAILING LOG"

    for wanted in interference inconclusive ok; do
        while IFS=$'\t' read -r verdict script_a script_b failing_side failing_log; do
            if [ "$verdict" != "$wanted" ]; then
                continue
            fi
            label="$script_a with $script_b"
            if [ "$script_a" = "$script_b" ]; then
                label="$label (self-pair)"
            fi
            printf '%-14s  %-40s  %-22s  %s\n' "$verdict" "$label" "$failing_side" "$failing_log"
        done < "$RESULTS"
    done
    echo

    if [ "${#SKIPPED_REASONS[@]}" -gt 0 ]; then
        selected_count="${#SELECTED[@]}"
        skipped_count="${#SKIPPED_REASONS[@]}"
        total_count=$((selected_count + skipped_count))
        missing_count=$(( total_count * (total_count + 1) / 2 - selected_count * (selected_count + 1) / 2 ))
        echo "Suites left out of this run:"
        for reason in "${SKIPPED_REASONS[@]}"; do
            echo "  $reason"
        done
        echo "  Combinations not checked as a result: $missing_count"
        echo
    fi

    if [ "$INCONCLUSIVE_COUNT" -gt 0 ]; then
        echo "Combinations skipped as inconclusive: $INCONCLUSIVE_COUNT"
        echo "  A script that fails on its own cannot be shown to have been broken by a partner."
        echo "  Run: bun run find-flakey-tests -- --script <name>"
        echo
    fi

    if [ "${#CRASH_LIST[@]}" -gt 0 ]; then
        echo "Bun crashes seen and retried (not counted as results):"
        for crash_line in "${CRASH_LIST[@]}"; do
            echo "  $crash_line"
        done
        echo
    fi
}

# How many devices were attached when the run started, so a pool that loses one mid-run is noticed.
# Only meaningful when a mobile suite is in the set: the other suites need no device, and a machine
# with an emulator up for something else must not stop this run.
DEVICE_COUNT_AT_START=0
case " ${SELECTED[*]} " in
    *" test:and "*)
        DEVICE_COUNT_AT_START="$(adb devices 2>/dev/null | grep -c "device$")"
        POOL_BRIDGE_COUNT_AT_START="$(pool_bridge_count)"
        ;;
esac

echo "check-parallel-tests: checking ${#SELECTED[@]} script(s): ${SELECTED[*]}"
echo "check-parallel-tests: $(( ${#SELECTED[@]} * (${#SELECTED[@]} + 1) / 2 )) combination(s) including self-pairs, each run once"
if [ -n "$COMMAND_TEMPLATE" ]; then
    echo "check-parallel-tests: each name is run as: $COMMAND_TEMPLATE"
fi
if [ "${#SKIPPED_REASONS[@]}" -gt 0 ]; then
    for skipped_reason in "${SKIPPED_REASONS[@]}"; do
        echo "check-parallel-tests: $skipped_reason"
    done
fi
if [ "$DEVICE_COUNT_AT_START" -gt 0 ]; then
    echo "check-parallel-tests: $DEVICE_COUNT_AT_START device(s) attached. The run stops if that changes or one stops answering."
    echo "check-parallel-tests: $POOL_BRIDGE_COUNT_AT_START pool emulator(s) on the LAN bridge. The run stops if a pair including test:and leaves fewer."
fi
echo "check-parallel-tests: logs in $SESSION_DIR"
echo

run_baseline_phase

touch "$RESULTS"
run_pair_phase
print_summary

if [ "$FOUND_INTERFERENCE" -eq 1 ]; then
    echo "check-parallel-tests: interference found. Two scripts that each pass alone fail when run together."
    echo "REPORT=$REPORT"
    echo "LOGS=$SESSION_DIR"
    exit 1
fi

if [ "$INCONCLUSIVE_COUNT" -gt 0 ]; then
    echo "check-parallel-tests: no interference found, but $INCONCLUSIVE_COUNT combination(s) could not be decided."
    if [ "$REPORT_STARTED" -eq 1 ]; then
        echo "REPORT=$REPORT"
    fi
    echo "LOGS=$SESSION_DIR"
    exit 5
fi

echo "check-parallel-tests: no interference found across $(( ${#SELECTED[@]} * (${#SELECTED[@]} + 1) / 2 )) combination(s)."
echo "LOGS=$SESSION_DIR"
exit 0
