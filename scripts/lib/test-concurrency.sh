#!/usr/bin/env bash

# How many tests a suite runs at once, in one place.
#
# Source this from a runner:
#   source "<repo>/scripts/lib/test-concurrency.sh"
#
# It defines functions only and does nothing when sourced.
#
# Why this is not just a number in each runner. Every suite used to carry a hardcoded batch size
# chosen when it was written, so a 24 core machine ran the Electron suite two tests at a time and
# nothing said why. Reading the machine gives a suite a width that suits the host it is on, and
# PHOTOSPHERE_TEST_PARALLEL is what lets a caller that knows better (scripts/test-everything-parallel.sh,
# which runs ten lanes at once) hand down a share instead.
#
# Written for the bash macOS ships, which is 3.2: no associative arrays, no mapfile, no ${var,,}.

# The most tests any suite will run at once when it sizes itself from the machine. A suite is one
# lane of a run that may hold ten, and every Electron test is a whole app and an X server, so a suite
# that took all 24 cores for itself would make the run it is part of slower rather than faster.
TEST_CONCURRENCY_MAX=6

# What the detected core count is divided by. The divisor and the cap above are the same judgement
# from two directions: a suite gets a slice of the machine, not the machine.
TEST_CONCURRENCY_CORE_DIVISOR=4

#
# Prints the number of cores usable on this host.
#
# Three sources, because no one of them is everywhere: getconf is POSIX and answers on Linux and
# macOS, nproc is coreutils (Linux, and the coreutils Git Bash ships), and sysctl is the BSD answer
# on macOS. A host where none of them answers gets 4 rather than an empty string, which would turn
# every arithmetic expression downstream into a syntax error.
# Usage: detect_cpu_count
#
detect_cpu_count() {
    local count
    count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
    if [ -z "$count" ]; then
        count="$(nproc 2>/dev/null || true)"
    fi
    if [ -z "$count" ]; then
        count="$(sysctl -n hw.ncpu 2>/dev/null || true)"
    fi
    case "$count" in
        ''|*[!0-9]*)
            echo 4
            ;;
        *)
            echo "$count"
            ;;
    esac
}

#
# Prints how many tests the calling suite should run at once.
#
# PHOTOSPHERE_TEST_PARALLEL wins when it holds a positive integer. Anything else in it is refused
# loudly and returns non-zero: a caller that meant to say 4 and typed "four" must hear about it, not
# silently get one test at a time and wonder why the run took an hour.
#
# Otherwise the machine decides: the core count divided by TEST_CONCURRENCY_CORE_DIVISOR, never below
# the fallback the suite passes (which is the width it used before it asked) and never above
# TEST_CONCURRENCY_MAX.
# Usage: resolve_test_parallel <fallback>
#
resolve_test_parallel() {
    local fallback="$1"
    local requested="${PHOTOSPHERE_TEST_PARALLEL:-}"
    if [ -n "$requested" ]; then
        case "$requested" in
            ''|*[!0-9]*)
                echo "resolve_test_parallel: PHOTOSPHERE_TEST_PARALLEL is set to '$requested', which is not a positive integer. Refusing to guess what was meant." >&2
                return 1
                ;;
        esac
        if [ "$requested" -lt 1 ]; then
            echo "resolve_test_parallel: PHOTOSPHERE_TEST_PARALLEL is set to '$requested', which is not a positive integer. Refusing to guess what was meant." >&2
            return 1
        fi
        echo "$requested"
        return 0
    fi

    local resolved
    resolved=$(( $(detect_cpu_count) / TEST_CONCURRENCY_CORE_DIVISOR ))
    if [ "$resolved" -lt "$fallback" ]; then
        resolved="$fallback"
    fi
    if [ "$resolved" -gt "$TEST_CONCURRENCY_MAX" ]; then
        resolved="$TEST_CONCURRENCY_MAX"
    fi
    echo "$resolved"
}
