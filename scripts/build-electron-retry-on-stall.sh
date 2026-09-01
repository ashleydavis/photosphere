#!/usr/bin/env bash
#
# Packages the Electron app, and retries once if the packaging stalls rather than fails.
#
# `build-desktop (windows-latest)` hangs in this build often enough to have its own registry entry,
# WINDOWS-ELECTRON-BUILD-HANGS-ON-NPM-LIST, with four sightings and no established cause. The last
# line before the silence is always the same: "note: bun does not support any CLI for dependency tree
# extraction, utilizing NPM node module collector instead". electron-builder has no dependency-tree
# reader for bun, so it falls back to spawning `npm list` in the repository root, and that child has
# no timeout of its own. Nothing here can make it come back, and nothing here can see why it did not.
#
# So the stall is made bounded instead. A stalled attempt is killed and tried again; the second
# attempt starts a fresh `npm list` and has always been enough so far, because the step is not
# normally slow at all. What this deliberately does NOT do is retry a build that failed: a build that
# is genuinely broken exits non-zero, which is not this, and it is reported on the first attempt so a
# real breakage is never hidden behind a second run of the same thing.
#
# The cap is per attempt, not for the pair. Healthy runs of this step take 107 to 156 seconds across
# the matrix legs, so seven minutes is about three times the slowest one, and two attempts plus their
# output still fit inside the step's own 20 minute cap, which stays as the outer limit.
#
# run_test_with_timeout comes from the test suites, but it is the one place in this repository that
# knows how to cap a command on Git Bash, where there is no timeout(1), and how to kill what it
# started through the process tree rather than by pid. Repeating that here to avoid borrowing a
# function with "test" in its name would be a second copy of the hard part.
#
# Usage: bash ./scripts/build-electron-retry-on-stall.sh
#

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=scripts/lib/test-timeout.sh
source "$REPO_DIR/scripts/lib/test-timeout.sh"

# Seconds one packaging attempt may take before it is treated as stalled.
ATTEMPT_SECONDS=420

# How many attempts a stall is given. Two: a stall that survives a fresh start is not the mode this
# is for, and a third attempt would only spend the step's remaining budget saying so.
MAX_ATTEMPTS=2

attempt=1
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do

    status=0
    run_test_with_timeout "$ATTEMPT_SECONDS" bun run build || status=$?

    if [ "$status" -eq 0 ]; then
        exit 0
    fi

    if ! test_timed_out "$status"; then
        echo "Packaging failed with exit code $status. That is a failure, not the stall this retry is for, so it is not retried."
        exit "$status"
    fi

    echo "Packaging attempt $attempt produced nothing for ${ATTEMPT_SECONDS}s and was killed. See WINDOWS-ELECTRON-BUILD-HANGS-ON-NPM-LIST in docs/flaky-tests-registry.md."
    attempt=$((attempt + 1))
done

echo "Packaging stalled on every attempt."
exit 1
