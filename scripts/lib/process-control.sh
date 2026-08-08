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
# The group is therefore the reliable form and the tree walk is only for a pid this library did not
# launch. The group is made with bash job control rather than `setsid`, which is util-linux and does
# not exist on macOS: with monitor mode on, the shell puts each background job in a new process group
# whose pgid is its pid. There is no host check and no reduced path anywhere below, so there is no
# platform where the cleanup quietly stops cleaning up while still reporting success. That job
# control does this is proven at runtime rather than assumed, once per shell, by
# process_control_verify_job_control, which refuses to launch anything if it does not.

# Whether bash job control has been shown, in this shell, to put a background job in a process group
# of its own: "yes" once proven, "no" once disproven, empty before the check has run.
PROCESS_CONTROL_JOB_CONTROL_VERIFIED=""

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
# Proves, once per shell, that turning on bash job control puts a background job in a process group
# of its own whose pgid is the job's own pid. Succeeds quietly and fails loudly.
#
# This exists so that nothing downstream has to assume it. A launched command can exit before its
# group can be read (a wrapper that starts a child and returns does exactly that), and the only
# honest thing to report for one of those is the pid, which is right only if job control did what it
# is supposed to. Proving it once here is what makes that report true rather than a guess, and a
# guessed process group is dangerous in a way a missed one is not: it names some other process's
# group, and the cleanup then kills whatever is in it.
#
# The probe is a real background job, because the question is what the kernel did and not what the
# manual says. It is killed as soon as its group has been read, so it costs one process spawn rather
# than the second its sleep asks for, and it happens once for the life of the shell.
# Usage: process_control_verify_job_control
#
process_control_verify_job_control() {
    if [ "$PROCESS_CONTROL_JOB_CONTROL_VERIFIED" = "yes" ]; then
        return 0
    fi
    if [ "$PROCESS_CONTROL_JOB_CONTROL_VERIFIED" = "no" ]; then
        return 1
    fi

    local own_pgid probe_pid probe_pgid monitor_was_on
    own_pgid="$(process_group_of "$$")"
    monitor_was_on="no"
    case "$-" in
        *m*)
            monitor_was_on="yes"
            ;;
    esac

    set -m
    sleep 1 &
    probe_pid=$!
    if [ "$monitor_was_on" = "no" ]; then
        set +m
    fi
    probe_pgid="$(process_group_of "$probe_pid")"
    kill "$probe_pid" 2>/dev/null || true

    if [ -n "$probe_pgid" ] && [ "$probe_pgid" = "$probe_pid" ] && [ "$probe_pgid" != "$own_pgid" ]; then
        PROCESS_CONTROL_JOB_CONTROL_VERIFIED="yes"
        return 0
    fi

    PROCESS_CONTROL_JOB_CONTROL_VERIFIED="no"
    echo "process_control_verify_job_control: bash job control did not put a background job in a process group of its own on this host (probe pid $probe_pid landed in group '$probe_pgid', this script is in group $own_pgid). The test suites cannot clean up reliably without that, so refusing to launch rather than reporting a process group that was never checked." >&2
    return 1
}

#
# Starts a command in the background with its output redirected to <log_file>, in a process group of
# its own, and prints "<pid> <pgid>" for the caller to record.
#
# The group comes from bash job control. With monitor mode on, the shell puts a background job in a
# new process group whose pgid is the job's own pid, so the group is known the instant the launch
# returns and nothing has to be polled for. Monitor mode is turned on for the launch alone and put
# back exactly as it was found, because leaving it on changes how the rest of the caller behaves.
#
# The pgid is therefore always set, and it is never the caller's own group, so a caller can pass what
# it reads here straight to kill_process_group.
#
# Read the two fields with:  read -r pid pgid < <(launch_in_process_group log cmd...)
# Environment for the command goes through `env`, e.g.
#   launch_in_process_group "$log" env FOO=1 some-command --flag
# Usage: launch_in_process_group <log_file> <argv...>
#
launch_in_process_group() {
    local log_file="$1"
    shift
    local launched_pid launched_pgid own_pgid monitor_was_on
    if ! process_control_verify_job_control; then
        return 1
    fi
    own_pgid="$(process_group_of "$$")"
    monitor_was_on="no"
    case "$-" in
        *m*)
            monitor_was_on="yes"
            ;;
    esac

    set -m
    "$@" > "$log_file" 2>&1 &
    launched_pid=$!
    if [ "$monitor_was_on" = "no" ]; then
        set +m
    fi

    # Read back from the kernel rather than assumed, so a host that behaves differently is caught
    # here instead of having its cleanup signal some other process's group.
    launched_pgid="$(process_group_of "$launched_pid")"
    if [ -z "$launched_pgid" ]; then
        # Nothing to read means the command exited before it could be looked at, which a wrapper
        # that starts a child and returns does routinely. Its group was its own pid: not assumed,
        # but resting on the check above, which proved that is what job control does here. The group
        # still matters even though the leader is gone, because whatever it started is still in it.
        launched_pgid="$launched_pid"
    fi
    if [ "$launched_pgid" = "$own_pgid" ]; then
        echo "launch_in_process_group: bash job control did not give '$1' a process group of its own on this host (it is still in group $own_pgid, which holds this script). Refusing to report a group that cannot be killed safely." >&2
        return 1
    fi

    # Recorded for the leak check, when a suite has asked for one by exporting the file to write to.
    # This is what makes the check specific to what this suite started: it names the exact groups,
    # not a pattern that other suites' processes also match.
    if [ -n "${PHOTOSPHERE_LAUNCHED_GROUPS:-}" ]; then
        echo "pgid $launched_pgid" >> "$PHOTOSPHERE_LAUNCHED_GROUPS"
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
# `ps -A` rather than `ps -e`: both list every process under procps, but the BSD ps on macOS reads
# -e as "show the environment too", which would put each process's whole environment in the output.
# -A means all processes on both.
#
list_leaked_launches() {
    local record_file="${PHOTOSPHERE_LAUNCHED_GROUPS:-}"
    if [ -z "$record_file" ] || [ ! -s "$record_file" ]; then
        return 0
    fi
    local snapshot
    snapshot="$(ps -A -o pid=,pgid=,args= 2>/dev/null || true)"
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
        esac
    done < "$record_file"
}
