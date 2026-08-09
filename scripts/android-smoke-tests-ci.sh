#!/usr/bin/env bash
#
# Runs the Android smoke tests on a CI runner, keeps the logcat whatever happens, and exits with the
# suite's own status.
#
# It exists because it has to be ONE command. The release workflow calls the suite through
# reactivecircus/android-emulator-runner, and that action splits its `script:` input on newlines and
# runs each line as a separate `sh -c` (see its src/script-parser.ts). So a multi-line script shares
# no variables between its lines, and a line's exit status dies with the shell that produced it.
#
# The workflow used to inline these four lines. The result was that a failing Android smoke test
# could not fail the job. `bun run test:and || status=$?` exits 0, because the assignment on the
# right of the `||` succeeds, and the `exit $status` on the last line ran in a fresh shell where
# `status` had never been set, so it exited 0 too. Every Android smoke test failure since then was
# reported as a green job: two were failing silently in the last release run before this was found.
#
# Putting it in a file makes the workflow's script a single line, which the action cannot split, and
# gives the exit-status handling somewhere it can be read and reviewed as shell rather than as a
# YAML string.
#
# The logcat dump is what makes the `|| status=$?` necessary at all: this script runs under `set -e`,
# so a plain call would end it the moment the suite failed and the dump would never happen. logcat is
# taken before the emulator is torn down because it is the only place the embedded worker's own
# output goes. app.log carries only what the WebView logged.
#
# Usage: bash ./scripts/android-smoke-tests-ci.sh
#

set -euo pipefail

# Where the workflow's upload-artifact step looks for the logs it keeps on a failure.
LOG_DIR="/tmp/photosphere-tests"

status=0
bun run test:and || status=$?

mkdir -p "$LOG_DIR"

# Never allowed to change the verdict: capturing evidence must not turn a failing suite into a pass,
# and a logcat that cannot be read is not a reason to fail a suite that passed.
adb logcat -d > "$LOG_DIR/logcat.txt" 2>&1 || true

exit "$status"
