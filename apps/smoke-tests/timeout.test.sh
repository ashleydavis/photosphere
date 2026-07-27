#!/usr/bin/env bash
# Tests lib/common.sh's run_with_timeout, in particular the shell fallback it uses where neither
# `timeout` nor `gtimeout` exists, which is every macOS machine and therefore every iOS run.
#
# The fallback is worth its own tests because it is invisible on Linux: `timeout` is always there, so
# nothing here exercises that path by accident, and a fault in it only ever shows up on macOS. One
# already did. The killer that enforces the cap inherited the caller's stdout, so when the caller was
# a pipeline or a $( ) capture the reader saw no end-of-file until the cap expired and every call took
# the full timeout no matter how fast the command was.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM="${PLATFORM:-android}"
export PLATFORM
source "$HERE/lib/common.sh" >/dev/null 2>&1

WORK="$(mktemp -d)"
fails=0
cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT

check() { # <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "ok   - $1"
    else
        echo "FAIL - $1 (expected '$2', got '$3')"
        fails=$((fails + 1))
    fi
}

#
# Prints a PATH holding everything the tests below need except `timeout` and `gtimeout`, so
# run_with_timeout takes its shell fallback on a machine that does have them.
#
path_without_timeout() {
    local dir="$WORK/no-timeout"
    mkdir -p "$dir"
    local tool source_path
    for tool in bash sh sleep echo cat tee kill pkill mktemp rm; do
        source_path="$(command -v "$tool" 2>/dev/null)" || continue
        ln -sf "$source_path" "$dir/$tool" 2>/dev/null || true
    done
    echo "$dir"
}

NO_TIMEOUT_PATH="$(path_without_timeout)"

echo "== run_with_timeout with timeout available =="

START="$SECONDS"
run_with_timeout 20 sleep 0
check "a fast command returns straight away" "yes" "$([ $((SECONDS - START)) -lt 5 ] && echo yes || echo no)"

run_with_timeout 20 sh -c 'exit 3'
check "the command's exit status is passed through" "3" "$?"

START="$SECONDS"
run_with_timeout 1 sleep 30
check "a command over the cap is stopped" "yes" "$([ $((SECONDS - START)) -lt 15 ] && echo yes || echo no)"

echo "== run_with_timeout falling back (no timeout, as on macOS) =="

# Each case runs in its own shell with the cut-down PATH, so the fallback is what is measured.
FALLBACK_DIRECT="$(PATH="$NO_TIMEOUT_PATH" bash -c '
    source "'"$HERE"'/lib/common.sh" >/dev/null 2>&1
    start=$SECONDS
    run_with_timeout 20 sleep 0
    echo $((SECONDS - start))
' 2>/dev/null)"
check "fallback: a fast command returns straight away" "yes" "$([ "${FALLBACK_DIRECT:-99}" -lt 5 ] && echo yes || echo no)"

# The regression. A pipeline reader must see end-of-file when the command finishes, not when the cap
# expires, so nothing the fallback spawns may keep the caller's stdout open.
FALLBACK_PIPED="$(PATH="$NO_TIMEOUT_PATH" bash -c '
    source "'"$HERE"'/lib/common.sh" >/dev/null 2>&1
    start=$SECONDS
    run_with_timeout 20 echo hello | tee /dev/null >/dev/null
    echo $((SECONDS - start))
' 2>/dev/null)"
check "fallback: piping the output does not wait out the cap" "yes" "$([ "${FALLBACK_PIPED:-99}" -lt 5 ] && echo yes || echo no)"

# The same fault, reached the other way: run_cli's callers read its output with $( ).
FALLBACK_CAPTURED="$(PATH="$NO_TIMEOUT_PATH" bash -c '
    source "'"$HERE"'/lib/common.sh" >/dev/null 2>&1
    start=$SECONDS
    captured="$(run_with_timeout 20 echo hello)"
    echo $((SECONDS - start))
' 2>/dev/null)"
check "fallback: capturing the output does not wait out the cap" "yes" "$([ "${FALLBACK_CAPTURED:-99}" -lt 5 ] && echo yes || echo no)"

FALLBACK_OUTPUT="$(PATH="$NO_TIMEOUT_PATH" bash -c '
    source "'"$HERE"'/lib/common.sh" >/dev/null 2>&1
    run_with_timeout 20 echo hello
' 2>/dev/null)"
check "fallback: the command's output still reaches the caller" "hello" "$FALLBACK_OUTPUT"

FALLBACK_STATUS="$(PATH="$NO_TIMEOUT_PATH" bash -c '
    source "'"$HERE"'/lib/common.sh" >/dev/null 2>&1
    run_with_timeout 20 sh -c "exit 3"
    echo $?
' 2>/dev/null)"
check "fallback: the command's exit status is passed through" "3" "$FALLBACK_STATUS"

FALLBACK_CAPPED="$(PATH="$NO_TIMEOUT_PATH" bash -c '
    source "'"$HERE"'/lib/common.sh" >/dev/null 2>&1
    start=$SECONDS
    run_with_timeout 1 sleep 30 >/dev/null 2>&1
    echo $((SECONDS - start))
' 2>/dev/null)"
check "fallback: a command over the cap is stopped" "yes" "$([ "${FALLBACK_CAPPED:-99}" -lt 15 ] && echo yes || echo no)"

echo ""
if [ "$fails" -eq 0 ]; then
    echo "All timeout tests passed."
else
    echo "$fails timeout test(s) failed."
fi
exit $((fails > 0 ? 1 : 0))
