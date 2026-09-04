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

# On Windows the root is held in the native form, because one directory must have one name.
#
# Git Bash rewrites an argument that looks like a POSIX path before a native binary sees it, and it
# does that only for arguments. A test that ran `psi init --db /tmp/photosphere-tests/x/db` created
# the database at C:/Users/.../Temp/photosphere-tests/x/db, then compared the CLI's output against
# the string it sent and failed. Worse, a path bash writes into a file is not an argument and is not
# rewritten, so the registry seeded by test 49 held the POSIX form while the database sat at the
# Windows one, and resolving the name found nothing. Holding the native form means there is nothing
# left to rewrite and both sides read the same string. `pwd -W` is how apps/cli/smoke-tests.sh
# already does this for its own directory. Unchanged on Linux and macOS.
if [[ "$OSTYPE" == "msys"* ]] || [[ "$OSTYPE" == "cygwin"* ]]; then
    mkdir -p "$PHOTOSPHERE_TEST_TEMP_ROOT"
    PHOTOSPHERE_TEST_TEMP_ROOT="$(cd "$PHOTOSPHERE_TEST_TEMP_ROOT" && pwd -W)"
fi

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
# Every variable is exported. PHOTOSPHERE_TMP_DIR is Photosphere's own setting for where it puts
# temporary files, which getProcessTmpDir() reads, so pointing it at the test's directory is what
# keeps the app's scratch files inside it. PHOTOSPHERE_CACHE_DIR does the same for the hash caches,
# which getCacheDir() reads and which live with the user's own data rather than in the temp
# directory, because a cache swept away costs a full re-hash of everything already imported.
# TEST_TMP_DIR is the shell-side name the CLI suites read for their own fixtures.
#
# The hash cache is set here rather than left to each suite because every suite needs it and only
# some of them set anything themselves: the desktop suite builds most of its fixtures by shelling out
# to the CLI from inside a test, and the mobile suite's create_database does the same, none of which
# names a directory of its own. One export here covers those and every suite written later.
#
# Exporting is the whole point. TEST_TMP_DIR was once set without being exported, so the CLI never
# saw it, every CLI process on the machine shared /tmp/photosphere, and `hash-cache clear` deleted it
# out from under a suite running alongside.
# Usage: photosphere_export_test_temp <dir>
#
photosphere_export_test_temp() {
    local dir="$1"
    export PHOTOSPHERE_TMP_DIR="$dir"
    export PHOTOSPHERE_CACHE_DIR="$dir/cache"
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
