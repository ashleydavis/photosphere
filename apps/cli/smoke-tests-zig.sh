#!/bin/bash

# Runs the Zig CLI smoke tests in smoke-tests-zig/: the Zig port of psi replicate and psi verify (apps/cli-zig),
# and the TypeScript/Zig interop tests proving a database made by one CLI can be verified and replicated by the
# other. The TypeScript CLI prepares the databases; replicate and verify run in the Zig CLI.
# Tests 07 onwards are copies of the existing CLI smoke tests that run psi replicate or psi verify
# (smoke-tests/, smoke-tests-encrypted.sh, sync-smoke-test.sh, write-lock-smoke-test.sh), with only
# those two commands switched to the Zig CLI.
#
# Usage: bash smoke-tests-zig.sh [test number or name]  (e.g. 07, 7, verify or 07-verify)

# Absolute path to this script's directory.
# On Windows (msys/cygwin), pwd returns a POSIX path (/d/a/...) that native .exe binaries cannot resolve,
# and Git Bash rewrites it only where it is a whole argument, so a test comparing a path the CLI printed
# with the one it passed would fail. pwd -W returns a Windows-style path (D:/a/...) that both bash and
# .exe understand, as smoke-tests.sh does.
if [[ "$OSTYPE" == "msys"* ]] || [[ "$OSTYPE" == "cygwin"* ]]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -W)"
else
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

# Absolute path to the Zig port of the CLI.
ZIG_CLI_DIR="$(cd "$SCRIPT_DIR/../cli-zig" && pwd)"

# Directory holding the Zig smoke tests.
TESTS_DIR="$SCRIPT_DIR/smoke-tests-zig"

# Root of the temporary directories the tests write to.
TMP_ROOT="$SCRIPT_DIR/test/tmp-zig"

# Deterministic UUIDs and plain output, as the other CLI smoke tests use.
export NODE_ENV=testing
export NO_COLOR=1

# Exit code a test uses to say it did not run its body, the same value smoke-tests.sh uses. A skip is
# reported and counted separately, never as a pass.
export TEST_SKIPPED_EXIT_CODE=77

cd "$SCRIPT_DIR"

echo "Building the Zig port of the CLI"
bun run --cwd "$ZIG_CLI_DIR" compile || exit 1

rm -rf "$TMP_ROOT"
mkdir -p "$TMP_ROOT"

passed=0
failed=0
skipped=0
failed_logs=()

# Returns 0 when the test directory is the one asked for on the command line: by its number (07 or 7)
# or by its name (the directory name without the number). With no argument every test runs.
is_selected_test() {
    local test_dir_name="$1"
    local requested="$2"
    local test_number="${test_dir_name%%-*}"
    if [ -z "$requested" ]; then
        return 0
    fi
    if [ "$requested" = "$test_number" ] || [ "$requested" = "${test_dir_name#*-}" ] || [ "$requested" = "$test_dir_name" ]; then
        return 0
    fi
    if [[ "$requested" =~ ^[0-9]+$ ]] && [ "$((10#$requested))" -eq "$((10#$test_number))" ]; then
        return 0
    fi
    return 1
}

for test_sh in "$TESTS_DIR"/[0-9]*/test.sh; do
    test_dir_name="$(basename "$(dirname "$test_sh")")"
    if ! is_selected_test "$test_dir_name" "${1:-}"; then
        continue
    fi

    export TEST_TMP_DIR="$TMP_ROOT/$test_dir_name"
    mkdir -p "$TEST_TMP_DIR"
    log_file="$TEST_TMP_DIR/test-run.log"
    start_time=$SECONDS
    test_status=0
    bash "$test_sh" > "$log_file" 2>&1 || test_status=$?
    if [ "$test_status" -eq 0 ]; then
        printf "PASS  %s  (%ss)\n" "$test_dir_name" "$((SECONDS - start_time))"
        passed=$((passed + 1))
    elif [ "$test_status" -eq "$TEST_SKIPPED_EXIT_CODE" ]; then
        printf "SKIP  %s  (%ss)  (log: %s)\n" "$test_dir_name" "$((SECONDS - start_time))" "$log_file"
        skipped=$((skipped + 1))
    else
        printf "FAIL  %s  (%ss)  (log: %s)\n" "$test_dir_name" "$((SECONDS - start_time))" "$log_file"
        failed=$((failed + 1))
        failed_logs+=("$log_file")
    fi
done

for log_file in "${failed_logs[@]}"; do
    echo ""
    echo "---------- $log_file ----------"
    cat "$log_file"
done

echo ""
echo "Results: $passed passed, $failed failed, $skipped skipped"

if [ "$failed" -gt 0 ] || [ "$((passed + skipped))" -eq 0 ]; then
    exit 1
fi
