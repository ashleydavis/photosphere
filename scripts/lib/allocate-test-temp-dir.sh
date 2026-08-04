#!/usr/bin/env bash

# Per-test temporary directories for the shell smoke-test runners.
#
# Every test, not every suite, owns a uniquely named directory for its fixtures, logs and scratch
# space, and gets one without opting in. Sharing a directory is how tests came to interfere with
# each other: one suite deleted /tmp/photosphere while another was writing its log header there,
# two concurrent mobile runs shared tests/<name>/tmp, and the desktop suite gave every run the same
# <test>/tmp inside the source tree.
#
# Source this from a runner or a test harness:
#   source "<repo>/scripts/lib/test-temp.sh"
#
# It defines functions only. Nothing here deletes anything: directories are left behind on purpose
# so the evidence from a failure survives, and photosphere_test_temp_count exists so the growth is
# visible rather than silent.

# The directory every per-test directory is created inside. Matches getTestTempRoot() in
# packages/node-utils/src/lib/test-temp-dir.ts when no per-test root is exported, so a count taken
# here and a directory created there agree on where the tree lives. Deliberately NOT the CLI's own
# "photosphere" directory under the same root, which product code such as `psi hash-cache clear`
# deletes outright.
PHOTOSPHERE_TEST_TEMP_ROOT="${TMPDIR:-/tmp}/photosphere-tests"

#
# Prints the directory that per-test directories are created inside, creating it if needed.
#
photosphere_test_temp_root() {
    mkdir -p "$PHOTOSPHERE_TEST_TEMP_ROOT"
    printf '%s\n' "$PHOTOSPHERE_TEST_TEMP_ROOT"
}

#
# Creates a directory belonging to one test and prints its absolute path.
#
# Uniqueness comes from mktemp, not from a timestamp or a counter: two tests starting in the same
# millisecond is exactly the case a timestamp misses. The label goes in the name so a directory left
# behind can be traced back to the test that made it, with anything that is not a letter, digit,
# dot, dash or underscore replaced so a label can never steer the path elsewhere.
# Usage: photosphere_test_temp_dir <label>
#
photosphere_test_temp_dir() {
    local label="$1"
    local safe_label
    safe_label="$(printf '%s' "$label" | tr -c 'A-Za-z0-9._-' '-')"
    mkdir -p "$PHOTOSPHERE_TEST_TEMP_ROOT"
    mktemp -d "$PHOTOSPHERE_TEST_TEMP_ROOT/${safe_label}-XXXXXX"
}

#
# Points every child process at the given test's directory, so the CLI and the app write their
# temporary files inside it rather than into a location shared with every other test.
#
# Both variables are exported: PHOTOSPHERE_TEST_TMP_ROOT is what getProcessTmpDir() prefers, and
# TEST_TMP_DIR is the older per-suite variable that parts of the CLI suites still read. Exporting is
# the whole point. TEST_TMP_DIR was once set without being exported, so the CLI never saw it, every
# CLI process on the machine shared /tmp/photosphere, and `hash-cache clear` deleted it out from
# under a suite running alongside.
# Usage: photosphere_export_test_temp <dir>
#
photosphere_export_test_temp() {
    local dir="$1"
    export PHOTOSPHERE_TEST_TMP_ROOT="$dir"
    export TEST_TMP_DIR="$dir"
}

#
# Prints how many per-test directories are currently under the test temp root.
#
# Nothing removes these, so this is the measure of the tree's growth. A harness that runs the suite
# many times prints it so an accumulation shows up on the run that caused it rather than weeks later
# as an unexplained slowdown.
#
photosphere_test_temp_count() {
    if [ ! -d "$PHOTOSPHERE_TEST_TEMP_ROOT" ]; then
        printf '0\n'
        return 0
    fi
    find "$PHOTOSPHERE_TEST_TEMP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '
}
