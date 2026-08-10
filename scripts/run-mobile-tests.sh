#!/usr/bin/env bash
set -euo pipefail

# Runs the mobile smoke tests for one platform, optionally narrowed to a single test.
#
# Usage: run-mobile-tests.sh <android|ios> [test-filter]
#
# This exists so `bun run test:and -- 45` reaches run.sh. `bun run` appends the arguments after `--`
# to the END of the whole command string it runs, not to the first command in it, so the previous
# `cd ... && bash ./run.sh && cd ../.. && what-changed baseline capture test:and` handed "45" to
# what-changed and ran the entire 43-test suite instead. Anything that has to take an argument has
# to be the last command in the chain, which means the chain itself belongs in a script.
#
# The baseline is captured only for a full run. `what-changed baseline capture test:and` asserts
# that the whole target passed, so stamping it after a single-test run would tell the change tracker
# the mobile suite was proven when one test of it was, and every other mobile test would then be
# skipped until something else changed.

PLATFORM_NAME="$1"
shift
TEST_FILTER="${1:-}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$PLATFORM_NAME" in
    android)
        BASELINE_TARGET="test:and"
        ;;
    ios)
        BASELINE_TARGET="test:ios"
        ;;
    *)
        echo "run-mobile-tests.sh: platform must be 'android' or 'ios', got '$PLATFORM_NAME'" >&2
        exit 1
        ;;
esac

# An empty filter selects every test, so this one call covers both the full run and a narrowed one.
(cd "$REPO_DIR/apps/smoke-tests" && PLATFORM="$PLATFORM_NAME" bash ./run.sh "$TEST_FILTER")

if [ -z "$TEST_FILTER" ]; then
    (cd "$REPO_DIR" && what-changed baseline capture "$BASELINE_TARGET")
fi
