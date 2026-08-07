#!/usr/bin/env bash

# Starting and stopping the background processes the test suites launch, in one place.
#
# Source this from a runner or a test harness:
#   source "<repo>/scripts/lib/process-control.sh"
#
# It defines functions only and does nothing when sourced.
#
# Why a process group rather than a walk of the process tree. A tree walk asks the kernel "who are
# this process's children", so it only works while the parent is still alive. The moment the parent
# dies its children are reparented to init, pgrep -P finds nothing, and the walk reports an empty
# tree while the survivors are sitting there holding memory. That is not an edge case: it is exactly
# the state a leak leaves behind, so the walk is at its least useful precisely when it is needed. A
# process group is a label the kernel keeps on each process, and reparenting does not change it, so
# `kill -- -<pgid>` still reaches every member however many parents have died in between.
#
# The group is therefore the reliable form and the tree walk is the fallback. Putting a command in a
# group of its own needs `setsid`, which is a util-linux program and is not present on macOS, so on
# macOS launch_in_process_group records no group and callers fall back to the tree walk. Everything
# here degrades to today's behaviour when the group is unavailable rather than failing.

# The checkout this library belongs to, resolved from this file's own location (scripts/lib) so it
# does not depend on the caller's working directory. Every "is this one of ours" decision below is
# made against this string, because several worktrees run suites at once on the same machine and
# killing another checkout's live run would be far worse than the leak this exists to clear.
PROCESS_CONTROL_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Worktrees live inside the checkout they were made from, so this checkout's path is a prefix of
# every worktree's path and a plain "contains the repo root" match would claim their processes too.
# Anything under here belongs to a different checkout and is never a candidate.
PROCESS_CONTROL_WORKTREES_PREFIX="$PROCESS_CONTROL_REPO_ROOT/.claude/worktrees/"

# How long, in units of PROCESS_CONTROL_GROUP_POLL_SECONDS, launch_in_process_group waits for setsid
# to move the command into its own group. The move happens between fork and exec, so a pgid read
# straight after the launch can still show the launching shell's group.
PROCESS_CONTROL_GROUP_POLL_ATTEMPTS=50
PROCESS_CONTROL_GROUP_POLL_SECONDS=0.05

# Seconds between the SIGTERM and the SIGKILL in the kill helpers, giving a process the chance to
# shut down on its own terms before it is taken out.
PROCESS_CONTROL_TERM_GRACE_SECONDS=1

#
# Prints the process group id of the given process, or nothing when it cannot be read (which
# includes a process that has already exited).
# Usage: process_group_of <pid>
#
process_group_of() {
    local pid="$1"
    if [ -z "$pid" ]; then
        return 0
    fi
    ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true
}

#
# Prints the given process and every process descended from it, deepest first.
#
# The list is gathered before anything is killed, on purpose: once a parent dies its children are
# reparented to init, so walking the tree afterwards finds nothing and the survivors are invisible.
# Usage: process_tree_pids <pid>
#
process_tree_pids() {
    local pid="$1"
    if ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    local child
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        process_tree_pids "$child"
    done
    echo "$pid"
}

#
# Stops the given process and everything it started, politely first and then not.
#
# This is the fallback form, and it can only see what is still attached to the given process. Prefer
# kill_process_group whenever a group id was recorded.
# Usage: kill_process_tree <pid>
#
kill_process_tree() {
    local pid="$1"
    if [ -z "$pid" ]; then
        return 0
    fi
    local tree_pid tree_pids
    tree_pids="$(process_tree_pids "$pid")"
    if [ -z "$tree_pids" ]; then
        return 0
    fi
    for tree_pid in $tree_pids; do
        kill -TERM "$tree_pid" 2>/dev/null || true
    done
    sleep "$PROCESS_CONTROL_TERM_GRACE_SECONDS"
    for tree_pid in $tree_pids; do
        kill -KILL "$tree_pid" 2>/dev/null || true
    done
}

#
# Stops every process in the given process group, politely first and then not. Reaches members whose
# parents have already died, which is what the tree walk cannot do.
#
# Refuses to act on the caller's own group and says so, because that group holds the calling script
# itself: a suite that killed it would take out its own runner mid-run and report the damage as a
# test failure. launch_in_process_group never records the caller's own group, so reaching this guard
# means a pgid came from somewhere it should not have.
# Usage: kill_process_group <pgid>
#
kill_process_group() {
    local pgid="$1"
    if [ -z "$pgid" ]; then
        return 0
    fi
    local own_pgid
    own_pgid="$(process_group_of "$$")"
    if [ "$pgid" = "$own_pgid" ]; then
        echo "kill_process_group refused to kill process group $pgid, which is this script's own group." >&2
        return 1
    fi
    kill -TERM -- "-$pgid" 2>/dev/null || true
    sleep "$PROCESS_CONTROL_TERM_GRACE_SECONDS"
    kill -KILL -- "-$pgid" 2>/dev/null || true
    return 0
}

#
# Starts a command in the background with its output redirected to <log_file>, in a process group of
# its own where that is possible, and prints "<pid> <pgid>" for the caller to record.
#
# The pgid field is empty when the command could not be given a group of its own (no setsid, so it
# stayed in the launching shell's group). An empty pgid is the signal to fall back to the tree walk;
# it is never the caller's own group, so a caller can pass whatever it reads here straight to
# kill_process_group without checking.
#
# Read the two fields with:  read -r pid pgid < <(launch_in_process_group log cmd...)
# Environment for the command goes through `env`, e.g.
#   launch_in_process_group "$log" env FOO=1 some-command --flag
# Usage: launch_in_process_group <log_file> <argv...>
#
launch_in_process_group() {
    local log_file="$1"
    shift
    local launched_pid launched_pgid own_pgid used_setsid
    own_pgid="$(process_group_of "$$")"
    if command -v setsid >/dev/null 2>&1; then
        used_setsid="yes"
        setsid "$@" > "$log_file" 2>&1 &
    else
        used_setsid="no"
        "$@" > "$log_file" 2>&1 &
    fi
    launched_pid=$!

    launched_pgid=""
    if [ "$used_setsid" = "yes" ]; then
        # setsid changes the group after the fork, so the new group is not there the instant the
        # launch returns. Poll for it, and give up the moment the process is gone: a command that
        # exits immediately must not cost the caller the whole polling window.
        local attempt=0
        local observed_pgid
        while [ "$attempt" -lt "$PROCESS_CONTROL_GROUP_POLL_ATTEMPTS" ]; do
            observed_pgid="$(process_group_of "$launched_pid")"
            if [ -n "$observed_pgid" ] && [ "$observed_pgid" != "$own_pgid" ]; then
                launched_pgid="$observed_pgid"
                break
            fi
            if ! kill -0 "$launched_pid" 2>/dev/null; then
                break
            fi
            sleep "$PROCESS_CONTROL_GROUP_POLL_SECONDS"
            attempt=$((attempt + 1))
        done
    fi

    # Recorded for the leak check, when a suite has asked for one by exporting the file to write to.
    # This is what makes the check specific to what this suite started: it names the exact groups,
    # not a pattern that other suites' processes also match.
    if [ -n "${PHOTOSPHERE_LAUNCHED_GROUPS:-}" ]; then
        if [ -n "$launched_pgid" ]; then
            echo "pgid $launched_pgid" >> "$PHOTOSPHERE_LAUNCHED_GROUPS"
        else
            echo "pid $launched_pid" >> "$PHOTOSPHERE_LAUNCHED_GROUPS"
        fi
    fi

    printf '%s %s\n' "$launched_pid" "$launched_pgid"
}

#
# Prints "<pid> <command line>", one per line, for everything still running that this suite started
# through launch_in_process_group, and nothing at all when there is none. Prints nothing when no
# suite asked to record launches.
#
# Scoped to the recorded process groups rather than to anything matching this checkout's path,
# because matching the path counts the processes of every OTHER suite running at the same moment.
# That is not a rare case: `bun run test:everything` runs five suites at once in one checkout, so a
# path match makes each of them report the other four's live processes as its own leak. The first
# full run through the git hook did exactly that, failing a CLI suite whose 79 tests had all passed
# over Electron and mobile processes that were still legitimately running in other lanes.
#
# A run on a machine with no setsid records pids instead of groups, so the check still works there,
# just without reaching a process whose parent has already died.
#
list_leaked_launches() {
    local record_file="${PHOTOSPHERE_LAUNCHED_GROUPS:-}"
    if [ -z "$record_file" ] || [ ! -s "$record_file" ]; then
        return 0
    fi
    local snapshot
    snapshot="$(ps -eo pid=,pgid=,args= 2>/dev/null || true)"
    if [ -z "$snapshot" ]; then
        return 0
    fi

    local kind identifier
    while read -r kind identifier; do
        [ -n "$identifier" ] || continue
        case "$kind" in
            pgid)
                printf '%s\n' "$snapshot" | awk -v want="$identifier" '$2 == want { $2 = ""; print }' || true
                ;;
            pid)
                printf '%s\n' "$snapshot" | awk -v want="$identifier" '$1 == want { $2 = ""; print }' || true
                ;;
        esac
    done < "$record_file"
}
