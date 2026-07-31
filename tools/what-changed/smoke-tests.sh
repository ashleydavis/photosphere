#!/bin/bash

# What changed smoke tests
#
# Drives the real CLI as a real process and asserts on its exit codes and output. That is the part
# the unit tests cannot reach: they call runGate directly and see a return value or an exception,
# where this sees what the shell sees.
#
# NOTHING HERE TOUCHES GIT. No repository is created, staged, committed or modified, and no git
# command that changes state is ever run. An earlier version of this script built a throwaway
# repository with `git init` and `git add -A`; those commands landed on the real repository instead
# and overwrote its branch pointer and index. A test that can rewrite the repository it runs inside
# is never worth what it covers.
#
# The cost of that rule is stated plainly rather than worked around: the gating behaviour itself
# (first run, unchanged run, changed paths, recording, --force, --plan, --files, --baseline) needs a
# git repository to exercise and is therefore NOT covered by any automated test. See README.md.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_PATH="$SCRIPT_DIR/src/cli.ts"

# A throwaway directory well away from any checkout. Deliberately not a git repository.
WORK_DIR="$(mktemp -d)"
OUTPUT_FILE="$WORK_DIR/cli-output.txt"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# The exit code of the most recent CLI run.
LAST_EXIT=0

# Counts of the checks that passed and failed, so every failure is reported rather than only the first.
PASS_COUNT=0
FAIL_COUNT=0

echo -e "${BLUE}=== What Changed Smoke Tests ===${NC}"
echo ""

# Announces a scenario, so the checks below it read as a group.
scenario() {
    echo -e "${YELLOW}$1${NC}"
}

# Records a passing check.
pass() {
    echo -e "  ${GREEN}PASS${NC} $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

# Records a failing check, printing the CLI's output so the failure can be read without a re-run.
fail() {
    echo -e "  ${RED}FAIL${NC} $1"
    echo "    --- CLI output ---"
    sed 's/^/    /' "$OUTPUT_FILE" || true
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# Runs the CLI from the throwaway directory, capturing its exit code and its output.
run_cli() {
    set +e
    (cd "$WORK_DIR" && bun "$CLI_PATH" "$@") > "$OUTPUT_FILE" 2>&1
    LAST_EXIT=$?
    set -e
}

# Asserts the CLI exited with the expected code.
assert_exit() {
    local expected="$1"
    if [ "$LAST_EXIT" = "$expected" ]; then
        pass "exit code $expected"
    else
        fail "expected exit code $expected, got $LAST_EXIT"
    fi
}

# Asserts the CLI exited with any non-zero code.
assert_failed() {
    if [ "$LAST_EXIT" != "0" ]; then
        pass "exited non-zero ($LAST_EXIT)"
    else
        fail "expected a non-zero exit, got 0"
    fi
}

# Asserts the CLI's output contains the given text.
assert_output_contains() {
    local expected="$1"
    # The -- matters: the expected text is often an option name like "--plan", which grep would
    # otherwise try to interpret as one of its own flags.
    if grep -qF -- "$expected" "$OUTPUT_FILE"; then
        pass "output mentions \"$expected\""
    else
        fail "expected the output to mention \"$expected\""
    fi
}

# Writes a valid config into the throwaway directory.
write_config() {
    cat > "$WORK_DIR/what-changed.json" <<'CONFIG'
{
    "runnerCommand": ["/bin/true"],
    "targets": [
        { "name": "alpha", "paths": ["dir-a"] }
    ]
}
CONFIG
}

scenario "1. --help prints the usage text and exits 0"
run_cli --help
assert_exit 0
assert_output_contains "--force"
assert_output_contains "--plan"
assert_output_contains "--files"
assert_output_contains "--baseline"

scenario "2. An unknown option fails, names it, and exits non-zero"
run_cli --nosuchoption
assert_failed
assert_output_contains "--nosuchoption"

scenario "3. --config with no value fails"
run_cli --config
assert_failed
assert_output_contains "needs a path"

scenario "4. A missing config file fails and names the path"
rm -f "$WORK_DIR/what-changed.json"
run_cli
assert_failed
assert_output_contains "what-changed.json"

scenario "5. A malformed config file fails rather than falling back to a default"
echo "{ not json" > "$WORK_DIR/what-changed.json"
run_cli
assert_failed
assert_output_contains "not valid JSON"

scenario "6. A config with a bad field fails and names the field"
echo '{ "runnerCommand": [], "targets": [] }' > "$WORK_DIR/what-changed.json"
run_cli
assert_failed
assert_output_contains "runnerCommand"

scenario "7. An unknown target name fails and names it"
write_config
run_cli nosuchtarget
assert_failed
assert_output_contains "nosuchtarget"

scenario "8. Running outside a git repository fails and names git"
write_config
run_cli --plan
assert_failed
assert_output_contains "git ls-files failed"

echo ""
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo -e "${RED}FAIL: $FAIL_COUNT check(s) failed, $PASS_COUNT passed${NC}"
    exit 1
fi

echo -e "${GREEN}PASS: all $PASS_COUNT checks passed${NC}"
echo ""
echo -e "${YELLOW}Note: the gating behaviour itself is not covered here. Exercising it needs a git${NC}"
echo -e "${YELLOW}repository, and no test in this project creates or modifies one. See README.md.${NC}"
