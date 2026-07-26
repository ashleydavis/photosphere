#!/usr/bin/env bash
# The single, definitive owner of the Android test:and run-lock. There is one emulator, so two
# `test:and` runs must not overlap; every acquisition of the lock goes through this script (both the
# real run and the standalone `hold` used for testing), so there is exactly one implementation of
# "take the lock" to reason about.
#
# Subcommands:
#   run <cmd...>   Acquire the lock, then exec <cmd...> under it. The lock is held for the whole life
#                  of the command and released automatically when it exits. `test:and` uses this to
#                  wrap the actual run. THIS (via run/hold) is the only way the lock is acquired.
#   hold           Acquire the lock and hold it until Ctrl-C. For exercising the locking on its own.
#   status         Print a definitive verdict: `free`, `locked (...)`, or `stale (...)`. Exit 0
#                  unless stale (1). Uses a non-blocking flock probe, not a guess.
#   unlock         Remove a stale lock, but only when no run is actually in progress.
set -euo pipefail

# Machine-wide lock path and how long to wait for it (then give up rather than hang forever). Both
# overridable via env for unusual setups.
LOCK_FILE="${PHOTOSPHERE_ANDROID_LOCK_FILE:-/tmp/photosphere-test-and.lock}"
LOCK_TIMEOUT="${PHOTOSPHERE_ANDROID_LOCK_TIMEOUT:-1800}"

log() { echo "[android-lock] $*" >&2; }

#
# True when the recorded PID is alive AND still has the lock file open, i.e. it is genuinely the
# current holder. Testing the open fd (not the process's command line) is what makes this correct
# even though `run` execs an arbitrary command whose name is not "run.sh", and it also rules out PID
# reuse: an unrelated process that reused a dead run's PID will not have our lock file open.
#
recorded_holder_holds_lock() {
    local pid="$1"
    [ -n "$pid" ] && [ -d "/proc/$pid" ] || return 1

    local target current fd
    target="$(readlink -f "$LOCK_FILE" 2>/dev/null || true)"
    [ -n "$target" ] || return 1
    for fd in /proc/"$pid"/fd/*; do
        current="$(readlink -f "$fd" 2>/dev/null || true)"
        if [ "$current" = "$target" ]; then
            return 0
        fi
    done
    return 1
}

recorded_holder() {
    # Must always succeed: under `set -e`, `holder="$(recorded_holder)"` would abort the caller if
    # this returned non-zero (e.g. no lock file).
    [ -f "$LOCK_FILE" ] || return 0
    head -1 "$LOCK_FILE" 2>/dev/null | tr -dc '0-9' || true
}

#
# Acquire the lock on fd 9. Announces a real wait (a silent block looks like a hang), gives up after
# LOCK_TIMEOUT, and records our PID for status/unlock. Opens read-write WITHOUT truncating so a run
# that is merely waiting cannot wipe the current holder's recorded PID.
#
acquire() {
    exec 9<>"$LOCK_FILE"
    if ! flock -n 9; then
        log "Another test:and run holds the lock ($LOCK_FILE). Waiting up to ${LOCK_TIMEOUT}s..."
        if ! flock -w "$LOCK_TIMEOUT" 9; then
            log "Gave up: the lock is still held after ${LOCK_TIMEOUT}s."
            log "If nothing is actually running, clear it with: $0 unlock"
            exit 1
        fi
        log "Lock acquired; continuing."
    fi
    printf '%s\n' "$$" > "$LOCK_FILE"
}

cmd_run() {
    if [ "$#" -eq 0 ]; then
        log "run needs a command: $0 run <cmd...>"
        exit 1
    fi
    acquire
    # exec keeps fd 9 open for the command's whole life, so the lock is held until it exits.
    exec "$@"
}

cmd_hold() {
    acquire
    # `sleep & wait` (not a bare `sleep`) so a trapped signal fires the release immediately instead
    # of being deferred until a foreground sleep returns.
    local sleep_pid=""
    trap 'log "Releasing the lock."; [ -n "$sleep_pid" ] && kill "$sleep_pid" 2>/dev/null; exit 0' INT TERM
    log "Holding the test:and lock (pid $$). Press Ctrl-C to release."
    while true; do
        sleep 86400 &
        sleep_pid=$!
        wait "$sleep_pid" || true
    done
}

cmd_status() {
    # Definitive: if a non-blocking flock grabs it (or there is no file), nobody holds it. The
    # read-only open never truncates the holder's recorded PID.
    if [ ! -e "$LOCK_FILE" ] || ( exec 8<"$LOCK_FILE"; flock -n 8 ) 2>/dev/null; then
        echo "free"
        return 0
    fi

    local holder
    holder="$(recorded_holder)"
    if recorded_holder_holds_lock "$holder"; then
        echo "locked (test:and running, pid $holder)"
        return 0
    fi

    echo "stale (held, but no test:and running; clear it with: $0 unlock)"
    return 1
}

cmd_unlock() {
    local holder
    holder="$(recorded_holder)"
    if recorded_holder_holds_lock "$holder"; then
        log "test:and is currently running (pid $holder). Not clearing the lock."
        return 1
    fi
    rm -f "$LOCK_FILE"
    log "Lock cleared ($LOCK_FILE)."
}

case "${1:-}" in
    run) shift; cmd_run "$@" ;;
    hold) cmd_hold ;;
    status) cmd_status ;;
    unlock) cmd_unlock ;;
    *)
        echo "Usage: $0 {run <cmd...>|hold|status|unlock}" >&2
        exit 1
        ;;
esac
