#!/usr/bin/env bash

# Shared library for the shell smoke-test runners: the per-run resources a suite must not share
# with anything else on the machine.
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

# LAN pairing codes for the shell smoke-test runners.
#
# Source this from a runner or a test harness:
#   source "<repo>/scripts/lib/test-lib.sh"
#
# It defines functions only. A suite must not share a code with anything else running on the machine,
# for the same reason it must not share a temp directory.
#
# A pairing code is the only thing that tells two shares apart on a network segment. A receiver
# announces sha256(code) to the whole subnet and a sender takes the first announcement whose hash
# matches the code it holds, so two shares on the same code are indistinguishable and a sender pairs
# with whichever it hears first.
#
# Drawing with $RANDOM out of nine thousand, which is what every caller used to do for itself, is
# not an allocation: two concurrent runs collide by luck. When they do, a receiver receives a payload
# meant for another run and the test that asserts its vault is empty fails, naming nothing that is
# actually wrong. Rare enough to look like a product bug and never reproduce.
#
# Another machine on the same subnet can still draw the same code, because nothing here can see it.
# That is a smaller problem than a second copy of a suite on this machine, which is the case
# `bun run test:parallel` exercises on purpose.

# Where held codes are recorded, one file per code, named by the code and holding the pid that took
# it. Beside the temp root rather than inside it, so a run that deletes its own directory does not
# release a code it is still using.
PHOTOSPHERE_PAIRING_CODE_DIR="${TMPDIR:-/tmp}/photosphere-pairing-codes"

#
# Prints a four digit pairing code no other live process on this machine holds, and records that this
# process holds it.
#
# A code is free when nothing names it, or when the file's owner is gone: a run killed part way
# through leaves its files behind and nothing else would clear them. Liveness is the test rather than
# an age, because a suite holds a code for minutes and a file whose owner has died is worthless the
# moment it dies.
#
# Usage: code="$(allocate_pairing_code)"
#
allocate_pairing_code() {
    mkdir -p "$PHOTOSPHERE_PAIRING_CODE_DIR"

    local code
    local holder
    local attempts=0

    # The claim itself is what keeps two callers apart, rather than a lock around a look and a claim.
    # `set -o noclobber` makes the redirection refuse to write a file that already exists, and it
    # refuses it in the one operation that creates it, so exactly one of two callers drawing the same
    # code can succeed and the other is told so and draws again.
    #
    # It used to be a lock, taken with `exec {lock_fd}>` and `flock`. Both are Linux-only: the
    # descriptor syntax needs bash 4 and macOS ships bash 3.2, and `flock` is util-linux and is not on
    # a Mac at all. So on macOS the lock was never taken, the shell said `exec: {lock_fd}: not found`
    # into the log, and two concurrent tests could draw the same code. That is what 78-dbs-share-cancel
    # and 79-secrets-share-cancel were failing on in CI, together, every time: two shares on one code
    # are indistinguishable on the network and the sender pairs with whichever it hears first.
    while true; do
        code=$(( (RANDOM % 9000) + 1000 ))

        if ( set -o noclobber; echo "$$" > "$PHOTOSPHERE_PAIRING_CODE_DIR/$code" ) 2>/dev/null; then
            break
        fi

        # Somebody holds it, or held it and died. A file whose holder is gone is worthless, so it is
        # removed and the code is drawn for again; whoever gets the claim in first wins it, because
        # the claim above is still the only thing that decides.
        holder="$(cat "$PHOTOSPHERE_PAIRING_CODE_DIR/$code" 2>/dev/null)"
        if [ -z "$holder" ] || ! kill -0 "$holder" 2>/dev/null; then
            rm -f "$PHOTOSPHERE_PAIRING_CODE_DIR/$code" 2>/dev/null
            continue
        fi

        attempts=$((attempts + 1))
        if [ "$attempts" -gt 100 ]; then
            # Nine thousand codes and a hundred misses means codes are leaking rather than that the
            # machine is busy. Say so instead of spinning.
            echo "Could not allocate a pairing code: $PHOTOSPHERE_PAIRING_CODE_DIR is full of live holders." >&2
            return 1
        fi
    done

    printf '%s\n' "$code"
}

#
# Prints an allocated pairing code that is not the one given, for the test that needs a sender's code
# to differ from its receiver's.
#
# Usage: wrong="$(allocate_different_pairing_code "$receiver_code")"
#
allocate_different_pairing_code() {
    local avoid="$1"
    local code
    while true; do
        code="$(allocate_pairing_code)" || return 1
        if [ "$code" != "$avoid" ]; then
            printf '%s\n' "$code"
            return 0
        fi
    done
}
