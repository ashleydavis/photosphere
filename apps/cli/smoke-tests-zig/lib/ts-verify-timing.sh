#!/bin/bash

# Timing for the TypeScript `psi verify` calls the Zig smoke suites make on every database the Zig
# CLI creates or modifies. Those calls run the reference implementation rather than the Zig CLI, so
# the suites record how long they take, and the Zig suites can be compared with the TypeScript
# suites both with and without them. Sourced by every Zig suite.

# The current time in milliseconds. EPOCHREALTIME (bash 5) gives microseconds; the bash 3.2 macOS
# ships lacks it, and there whole seconds from date are the best available.
current_milliseconds() {
    if [ -n "${EPOCHREALTIME:-}" ]; then
        local epoch_microseconds="${EPOCHREALTIME/[.,]/}"
        echo $((10#$epoch_microseconds / 1000))
    else
        echo $(($(date +%s) * 1000))
    fi
}

# Appends the milliseconds one TypeScript verify took to a timing log, one line per call.
# Usage: record_ts_verify_milliseconds <log file> <start milliseconds>
record_ts_verify_milliseconds() {
    local timing_log="$1"
    local start_milliseconds="$2"
    echo $(($(current_milliseconds) - start_milliseconds)) >> "$timing_log"
}

# Prints the total milliseconds recorded in the timing logs given, and 0 when there are none.
# Usage: sum_ts_verify_milliseconds <log file>...
sum_ts_verify_milliseconds() {
    local total_milliseconds=0
    local timing_log
    local elapsed_milliseconds
    for timing_log in "$@"; do
        if [ ! -f "$timing_log" ]; then
            continue
        fi
        while IFS= read -r elapsed_milliseconds; do
            if [ -n "$elapsed_milliseconds" ]; then
                total_milliseconds=$((total_milliseconds + elapsed_milliseconds))
            fi
        done < "$timing_log"
    done
    echo "$total_milliseconds"
}

# Prints the number of TypeScript verify calls recorded in the timing logs given.
# Usage: count_ts_verify_calls <log file>...
count_ts_verify_calls() {
    local call_count=0
    local timing_log
    local elapsed_milliseconds
    for timing_log in "$@"; do
        if [ ! -f "$timing_log" ]; then
            continue
        fi
        while IFS= read -r elapsed_milliseconds; do
            if [ -n "$elapsed_milliseconds" ]; then
                call_count=$((call_count + 1))
            fi
        done < "$timing_log"
    done
    echo "$call_count"
}

# Formats milliseconds as seconds with one decimal place, for the suite summaries.
# Usage: format_milliseconds_as_seconds <milliseconds>
format_milliseconds_as_seconds() {
    local milliseconds="$1"
    echo "$((milliseconds / 1000)).$(((milliseconds % 1000) / 100))s"
}
