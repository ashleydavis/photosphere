#!/usr/bin/env bash
# Keeps the Android emulator pool up, and shows what it is doing. Started with no arguments, it:
#
#   1. brings the pool up when it is not there, by calling `emulator.sh pool-up`
#   2. repairs every pool emulator that is not healthy, one at a time
#   3. carries on watching, repairing each one as it goes bad
#
# Step 1 is the only thing here that can ask for a password, and only when the bridge or the taps
# have to be made, which is the one part of the pool that needs root. Steps 2 and 3 need nothing.
#
# How it shows itself picks itself, rather than being asked for. On a terminal it draws the table of
# emulators with live CPU, memory and swap graphs beneath it, rewritten in place so the terminal
# holds one display rather than a growing pile of them; the graphs are there for correlation, since
# when an emulator goes red the history to the left of that moment shows what the machine was doing
# in the run-up to it. Redirected to a file it prints one timestamped line per pass instead, because
# a redraw-in-place display is unreadable in a log.
#
# Healthy means all three of: adb lists the device as `device` rather than offline or unauthorized,
# the guest reports sys.boot_completed, and wlan0 holds a 192.168.55.x address. That last one is the
# same condition the smoke tests require, so a row reading Healthy means the tests can use it. The
# judgement itself lives in emulator-status-lib.sh, which the pool status check and emulator.sh's
# repair path also read, so none of them can call an emulator healthy while another calls it broken.
#
# What it will and will not touch. It watches every attached emulator, including a hand-testing one,
# and repairs only pool indexes: a hand-testing emulator appears in the table and is never restarted.
# It repairs by calling `emulator.sh pool-repair --index N`, which takes that emulator's harness lock
# first, so an emulator a test run is using is reported and left alone. It never removes a tap or the
# bridge.
#
# Usage:
#   apps/android-frontend/scripts/emulator-pool-monitor.sh   # bun run emu:and:pool:monitor
#
# It takes no arguments. There is one thing to do with a pool monitor and this does it.
#
# Press Ctrl-C to stop.
set -uo pipefail

# Where this script lives, used to reach the files it shares with the rest of the pool tooling.
MONITOR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The device lock path (so a test run's emulator is never restarted underneath it) and the health
# judgement itself. Both are sourced rather than written out again here.
source "$MONITOR_SCRIPT_DIR/emulator-config.sh"
source "$MONITOR_SCRIPT_DIR/emulator-status-lib.sh"

# kill_process_tree, for taking a background repair down with the monitor when it is interrupted.
source "$MONITOR_SCRIPT_DIR/../../../scripts/lib/process-control.sh"

# The pool lifecycle script. This is the only thing here that can change anything, and it is reached
# as a separate process rather than sourced, so nothing in this file can start or stop an emulator by
# itself: the repair goes through `pool-repair`, which refuses to run as root, refuses when the
# bridge is gone, and takes each emulator's lock before it touches it.
EMULATOR_SCRIPT="$MONITOR_SCRIPT_DIR/emulator.sh"

# How long between frames. One second, because this is what sets the graphs' resolution: a sample per
# second is fine enough to show a spike without making the history cover only a few moments.
SAMPLE_SECONDS=1

# How many samples between emulator health checks. The graphs come from /proc and cost nothing, but a
# health check is several adb calls per emulator, and adb is already busy serving the test run. Every
# third sample keeps that load down while still noticing an emulator within a few seconds.
HEALTH_EVERY_SAMPLES=3

# How long any single adb call may take before it is abandoned. An adb that wedges would otherwise
# hang the whole watch, and a display frozen on stale rows is worse than one that says so. From
# emulator-status-lib.sh, so the calls this file makes directly are held to the same limit as the
# ones the library makes for it.
ADB_TIMEOUT_SECONDS="$EMULATOR_STATUS_ADB_TIMEOUT_SECONDS"

# Seconds between passes, and so between repairs.
#
# Five. This was a minute, on the grounds that a repair is a cold boot taking minutes and looking
# more often would keep finding the same emulator still booting. What that missed is the wait before
# anything starts: an emulator that died a second after a pass sat there dead for the rest of the
# minute while the display showed it, which was most of the time between the crash and the fix.
# Looking every five seconds costs a few adb calls and takes the usual repair down to about the
# length of the boot itself.
#
# The environment overrides it, which is how the numbers below can be exercised without waiting out
# the real ones. Not an argument: nobody typing this command has a reason to choose.
MONITOR_INTERVAL_SECONDS="${MONITOR_INTERVAL_SECONDS:-5}"

# How many repairs of one index may fail in a row before this waits a while before trying it again.
#
# Without a limit a machine-level fault turns into an endless cold-boot loop that makes the machine
# worse, which is close to what the recovery attempts on 2026-08-09 did by hand: emulator after
# emulator started into a state where it burned no CPU and opened nothing, and each attempt cost the
# machine another few gigabytes. Reaching this limit starts the wait below rather than abandoning the
# index.
MONITOR_MAX_CONSECUTIVE_FAILURES="${MONITOR_MAX_CONSECUTIVE_FAILURES:-3}"

# How long an index is left alone after a run of failed repairs, and the longest that wait may grow
# to. It doubles each time a run of repairs fails: ten minutes, twenty, forty, then an hour from then
# on.
#
# This used to be permanent: an index whose repairs failed three times in a row was never restarted
# again for the life of the monitor. On 2026-08-12 that stranded three of the five emulators for
# hours. Every one of those repairs had failed the same way, `did not reach the bridge within 420s`,
# because the machine was loaded at the time, and a loaded machine is temporary. The proof is in the
# same log: index 1 failed twice and came back on the third attempt, and when the monitor was
# restarted the three abandoned emulators each repaired first time in about thirty seconds. Nothing
# was wrong with them that another attempt would not have fixed, and the monitor had stopped making
# any.
#
# So a failing index is now waited on rather than abandoned, and the wait grows so a genuine
# machine-level fault still cannot turn into a cold-boot loop. At the longest wait an index costs the
# machine three cold boots an hour, against the 720 an unlimited retry would attempt.
MONITOR_BACKOFF_SECONDS="${MONITOR_BACKOFF_SECONDS:-600}"
MONITOR_MAX_BACKOFF_SECONDS="${MONITOR_MAX_BACKOFF_SECONDS:-3600}"

# How long a healthy pool emulator may stay up before it is recycled while nothing is using it.
#
# Twelve hours. The five emulators that died had been up 23.5 hours and were holding 6.6 to 6.7GB of
# resident memory plus up to 2GB of swap each. Recycling one while it is idle costs a cold boot
# nobody is waiting on; not recycling it costs the pool during a test run.
MONITOR_MAX_UPTIME_SECONDS="${MONITOR_MAX_UPTIME_SECONDS:-43200}"

# Where the one repairing monitor on this machine holds its lock.
#
# A fixed path, deliberately, and the rule in CLAUDE.md about fixed paths does not reach it: that
# rule is about tests, which must survive running beside a second copy of themselves. This is not a
# test. It manages a machine-wide resource that already has fixed names (br-psphere, psphere-pool-N,
# emu-pool-N), and two monitors repairing one pool would fight over it, each restarting emulators the
# other was waiting on. A second copy of this must not run at all, so a shared name is what is
# wanted. A read-only run takes no lock, so any number of people can watch at once.
MONITOR_LOCK_PATH="/tmp/photosphere-emulator-pool-monitor.lock"

# Whether a start has already been attempted for the current outage, so a machine with no bridge and
# nobody at the keyboard is asked for a password once rather than once a minute for ever. Reset the
# moment the pool is up again, so a later outage gets its own attempt.
MONITOR_START_ATTEMPTED="no"

# Whether this is drawing a table on a terminal, which decides how a repair is run: in the background
# with the emulator shown as repairing in the table, or in the foreground printing as it goes.
MONITOR_ON_TERMINAL="no"
if [ -t 1 ]; then
    MONITOR_ON_TERMINAL="yes"
fi

# The repair running right now, if there is one: its process and the index it is fixing. Recorded the
# moment it is started, so the loop can notice it finishing and Ctrl-C can take it down.
MONITOR_REPAIR_PID=""
MONITOR_REPAIR_INDEX=""

# Where a background repair's output goes. Appended to, so the account of a repair that failed an hour
# ago is still there. A fixed path for the same reason the monitor's lock has one: there is one
# monitor on this machine. It lives in /tmp, so a reboot clears it.
MONITOR_REPAIR_LOG_PATH="/tmp/photosphere-emulator-pool-monitor-repairs.log"


#
# Prints the usage block from the comment at the top of this file, so there is one copy of it rather
# than two that drift apart.
#
print_usage() {
    sed -n '/^# Usage:$/,/^# Press Ctrl-C to stop\.$/p' "${BASH_SOURCE[0]}" \
        | sed '$d' \
        | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h)
            print_usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            echo "" >&2
            print_usage >&2
            exit 1
            ;;
    esac
    shift
done

# Column widths for the table. The serial column fits "emulator-5554" with room to spare, and the
# status column fits "Unhealthy" plus a gap.
SERIAL_WIDTH=16
STATUS_WIDTH=12

# Width of the pool column, which fits "pool-2" and "single" with a gap.
#
# The column exists because an emulator answers to three names and only one of them is ours. The pool
# index names its AVD (psphere-pool-2), its tap (emu-pool-2), its systemd unit (psphere-emu-pool-2)
# and its log, and it is what every repair message says. The adb serial is assigned by the emulator
# from whichever console port it grabs at launch, so it changes when an emulator is restarted and it
# says nothing about which index it is. Showing only the serial meant the table and the repair
# messages appeared to be about different machines.
POOL_WIDTH=8

# Column widths for each emulator's own CPU and memory. Right-aligned, so "4%" and "40%" line up and
# the eye can compare down the column.
CPU_WIDTH=4
MEMORY_WIDTH=10

# The blocks the graphs are drawn from, lowest to highest, and how many there are. A value is mapped
# onto one of these by its percentage, so each column is one sample.
GRAPH_BLOCKS=("▁" "▂" "▃" "▄" "▅" "▆" "▇" "█")
GRAPH_BLOCK_COUNT=8

# Colours, empty when stdout is not a terminal so a redirected run records plain text rather than
# escape sequences.
if [ -t 1 ]; then
    COLOUR_GREEN=$'\033[0;32m'
    COLOUR_RED=$'\033[0;31m'
    COLOUR_PURPLE=$'\033[0;35m'
    COLOUR_DIM=$'\033[0;90m'
    COLOUR_OFF=$'\033[0m'
else
    COLOUR_GREEN=""
    COLOUR_RED=""
    COLOUR_PURPLE=""
    COLOUR_DIM=""
    COLOUR_OFF=""
fi

# How wide the graphs are, in samples. Sized from the terminal so the display does not wrap, because a
# wrapped line would throw off the cursor arithmetic that redraws in place. Clamped at both ends so a
# very narrow or very wide terminal still gets something sensible.
graph_width=60
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    terminal_columns="$(tput cols 2>/dev/null || echo 92)"
    graph_width=$(( terminal_columns - 32 ))
fi
if [ "$graph_width" -lt 20 ]; then
    graph_width=20
fi
if [ "$graph_width" -gt 120 ]; then
    graph_width=120
fi

# How many lines the display currently occupies, so the next frame knows how far to move the cursor
# back up to overwrite it. Zero means nothing has been drawn yet.
lines_drawn=0

# The rolling histories the graphs are drawn from, oldest first, each capped at graph_width samples.
cpu_history=()
memory_history=()
swap_history=()
health_history=()

# The previous /proc/stat totals, so CPU can be worked out from the change between two samples rather
# than reported as the average since the machine booted, which never moves.
previous_busy=0
previous_total=0

# How many processors the machine has. Per-emulator CPU is reported as a share of the whole machine
# rather than of one core, so the emulator figures and the CPU graph above them are in the same units
# and can be read against each other.
processor_count="$(nproc 2>/dev/null || echo 1)"

# The machine's total memory in bytes. Used as the denominator for an emulator that carries no memory
# limit of its own, so its column still reads as a share of something real.
machine_memory_bytes="$(awk '/^MemTotal:/ { print $2 * 1024 }' /proc/meminfo)"

# Each emulator's AVD name and control-group path, keyed by adb serial. Both are fixed for as long as
# an emulator lives, and finding them costs an adb round trip and a process search, so they are looked
# up once rather than every time the table is refreshed.
declare -A avd_by_serial=()
declare -A cgroup_by_serial=()

# The previous CPU reading for each emulator, and when it was taken, so CPU can be worked out from the
# change between two readings. Microseconds of CPU consumed, and a nanosecond wall clock stamp.
declare -A cpu_usec_by_serial=()
declare -A cpu_stamp_by_serial=()

# The last known table row for each emulator, keyed by adb serial, as "status|detail|cpu|memory".
# Kept because emulators are checked in rotation rather than all at once, so every frame needs the
# readings taken on earlier turns to fill the rows it did not visit this time.
declare -A row_by_serial=()

#
# Restores the cursor and leaves the finished display on screen. Bound to Ctrl-C so quitting does not
# leave the terminal with a hidden cursor.
#
restore_terminal() {
    if [ -t 1 ]; then
        printf '\033[?25h'
    fi
    echo

    # A repair started in the background is this monitor's process and goes with it, rather than
    # being left restarting an emulator nobody is watching any more. Its tree, not its pid: the repair
    # is a shell script whose own children hold the work. Stopping it part way is safe, because every
    # step it takes is one pool-repair or the monitor itself would take again from wherever it got to.
    if [ -n "$MONITOR_REPAIR_PID" ]; then
        echo "Stopping the repair of pool-$MONITOR_REPAIR_INDEX that was still running."
        kill_process_tree "$MONITOR_REPAIR_PID"
    fi

    exit 0
}

#
# Prints "<serial> <state>" for every device adb can see, one per line. The state is adb's own word
# for it: device, offline, unauthorized.
#
attached_devices() {
    timeout "$ADB_TIMEOUT_SECONDS" adb devices 2>/dev/null | awk 'NR > 1 && NF >= 2 { print $1, $2 }'
}

#
# Prints "<status>|<detail>" for one emulator, where status is Healthy or Unhealthy and detail says
# either where it is on the bridge or what is wrong with it.
#
# The readings come from emulator-status-lib.sh; what is here is the wording of the row. An emulator
# that answered nothing is reported as exactly that, and not as "still booting" or "off the lan
# bridge": one thrashing on memory stays listed by adb as a device and accepts the connection while
# answering nothing, and either of those words would state something definite that has not been
# established.
# Usage: health_of <serial> <adb_state>
#
health_of() {
    local serial="$1"
    local adb_state="$2"
    local booted report

    if [ "$adb_state" != "device" ]; then
        echo "Unhealthy|adb says $adb_state"
        return 0
    fi

    booted="$(emulator_boot_completed "$serial")"
    if [ -z "$booted" ]; then
        echo "Unhealthy|not answering adb"
        return 0
    fi
    if [ "$booted" != "1" ]; then
        echo "Unhealthy|still booting"
        return 0
    fi

    report="$(emulator_wlan_report "$serial")"
    case "$report" in
        address\ *)
            echo "Healthy|${report#address }"
            ;;
        no-answer)
            echo "Unhealthy|not answering adb"
            ;;
        no-carrier)
            echo "Unhealthy|off the lan bridge, wifi down"
            ;;
        *)
            echo "Unhealthy|off the lan bridge, no address"
            ;;
    esac
}

#
# Prints the name this project knows an emulator by, from the AVD it is running: "pool-<index>" for a
# pool emulator, "single" for the hand-testing one, the AVD's own name for anything else, and "?"
# when nobody has asked it yet.
# Usage: pool_label_for_serial <serial>
#
pool_label_for_serial() {
    local avd="${avd_by_serial[$1]:-}"

    case "$avd" in
        "$POOL_AVD_PREFIX"-*)
            echo "pool-${avd#"$POOL_AVD_PREFIX"-}"
            ;;
        "$SINGLE_AVD_NAME")
            echo "single"
            ;;
        ?*)
            echo "$avd"
            ;;
        *)
            echo "?"
            ;;
    esac
}

#
# Prints the control group directory holding one emulator's processes, or nothing when it cannot be
# found. Looked up by the emulator's AVD name, which is what its command line carries.
#
# The control group is used rather than the emulator's main process because an emulator is a tree of
# them, and the main process alone accounts for only part of what it costs. The path is checked for
# the pool's own unit name before it is accepted: an emulator started outside this project sits in
# whatever group its shell is in, and reporting that group's usage would credit the emulator with
# everything else running in the same terminal.
#
# Usage: cgroup_dir_for_avd <avd_name>
#
cgroup_dir_for_avd() {
    local avd="$1"
    local pid cgroup_path

    pid="$(pgrep -f -- "-avd $avd" 2>/dev/null | head -1)"
    if [ -z "$pid" ]; then
        return 0
    fi

    cgroup_path="$(awk -F: '$1 == "0" { print $3 }' "/proc/$pid/cgroup" 2>/dev/null)"
    case "$cgroup_path" in
        *psphere-emu-*) ;;
        *) return 0 ;;
    esac

    if [ -d "/sys/fs/cgroup$cgroup_path" ]; then
        echo "/sys/fs/cgroup$cgroup_path"
    fi
}

#
# Sets emulator_cpu_result and emulator_memory_result for one emulator, to a percentage and a figure
# in gigabytes, or to "?" when they cannot be read.
#
# CPU comes from the change in the group's consumed CPU time over the wall time between two readings,
# expressed as a share of every processor the machine has. Memory is the group's current usage.
#
# The answers are returned in globals rather than printed, because working out CPU means remembering
# the previous reading, and a function called through a command substitution runs in a subshell whose
# variables are thrown away. Written that way it forgot every reading and reported "?" forever.
#
# A question mark rather than a zero when the figures are unavailable, because zero would read as an
# emulator using nothing, which is a different and much more alarming claim than not knowing.
#
# Usage: emulator_usage <serial>
#
emulator_usage() {
    local serial="$1"
    local cgroup_dir usage_usec memory_bytes memory_limit now_nsec
    local previous_usec previous_stamp elapsed_nsec

    emulator_cpu_result="?"
    emulator_memory_result="?"

    cgroup_dir="${cgroup_by_serial[$serial]:-}"
    if [ -z "$cgroup_dir" ] || [ ! -d "$cgroup_dir" ]; then
        return 0
    fi

    # `anon` from memory.stat, not memory.current.
    #
    # memory.current counts page cache, and cache expands to fill whatever allowance it is given and
    # is handed straight back when anything needs it. A healthy emulator therefore reads close to
    # 100% and the column says nothing, which is worse than showing no column: a reading of 99% on an
    # emulator using 3.6GB of its 8GB looks like an emergency and is not one.
    #
    # `anon` is memory that cannot be reclaimed, so it is the figure that decides whether an emulator
    # is in trouble. It was 4.7GB against a 5GB limit when the pool collapsed, and 3.6GB against 8GB
    # on the same emulators once they had room.
    memory_bytes="$(awk '/^anon /{ print $2 }' "$cgroup_dir/memory.stat" 2>/dev/null || true)"
    usage_usec="$(awk '/^usage_usec/ { print $2 }' "$cgroup_dir/cpu.stat" 2>/dev/null || true)"
    case "$memory_bytes$usage_usec" in
        ''|*[!0-9]*) return 0 ;;
    esac

    # Both the figure and the share of the limit, because each answers a question the other cannot.
    # Gigabytes say how big the emulator is and can be compared against any other tool; the
    # percentage says how close it is to being throttled, which needs the limit to interpret.
    memory_limit="$(cat "$cgroup_dir/memory.high" 2>/dev/null || true)"
    case "$memory_limit" in
        ''|*[!0-9]*) memory_limit="$machine_memory_bytes" ;;
    esac
    if [ "$memory_limit" -gt 0 ]; then
        emulator_memory_result="$(awk -v bytes="$memory_bytes" -v limit="$memory_limit" \
            'BEGIN { printf "%.1fG %d%%", bytes / 1073741824, bytes * 100 / limit }')"
    else
        emulator_memory_result="$(awk -v bytes="$memory_bytes" 'BEGIN { printf "%.1fG", bytes / 1073741824 }')"
    fi

    now_nsec="$(date +%s%N)"
    previous_usec="${cpu_usec_by_serial[$serial]:-}"
    previous_stamp="${cpu_stamp_by_serial[$serial]:-}"
    cpu_usec_by_serial["$serial"]="$usage_usec"
    cpu_stamp_by_serial["$serial"]="$now_nsec"

    if [ -n "$previous_usec" ] && [ -n "$previous_stamp" ]; then
        elapsed_nsec=$(( now_nsec - previous_stamp ))
        if [ "$elapsed_nsec" -gt 0 ]; then
            # Consumed microseconds against elapsed microseconds across every processor. The
            # multiply comes before the divide, because this is integer arithmetic and dividing
            # first would round the answer away.
            emulator_cpu_result=$(( (usage_usec - previous_usec) * 100 / (elapsed_nsec / 1000 * processor_count) ))
            if [ "$emulator_cpu_result" -lt 0 ]; then
                emulator_cpu_result=0
            fi
            if [ "$emulator_cpu_result" -gt 100 ]; then
                emulator_cpu_result=100
            fi
        fi
    fi
}

#
# Prints the machine's CPU use since the previous call, as a whole-number percentage.
#
# Worked out from the change in /proc/stat rather than its raw values, because those are totals since
# boot: read once they describe the whole uptime and barely move, which is not what anyone watching a
# test run wants to see. Idle and iowait both count as not-busy.
#
sample_cpu_percent() {
    local fields busy total busy_delta total_delta percent
    # shellcheck disable=SC2207
    fields=($(awk '/^cpu / { print; exit }' /proc/stat))
    if [ "${#fields[@]}" -lt 5 ]; then
        echo 0
        return 0
    fi

    total=0
    local index value
    for index in $(seq 1 $(( ${#fields[@]} - 1 ))); do
        value="${fields[$index]}"
        total=$(( total + value ))
    done
    # Fields after the name are user, nice, system, idle, iowait, ... so idle is 4 and iowait is 5.
    busy=$(( total - fields[4] - fields[5] ))

    busy_delta=$(( busy - previous_busy ))
    total_delta=$(( total - previous_total ))
    previous_busy="$busy"
    previous_total="$total"

    if [ "$total_delta" -le 0 ]; then
        echo 0
        return 0
    fi
    percent=$(( busy_delta * 100 / total_delta ))
    if [ "$percent" -lt 0 ]; then
        percent=0
    fi
    if [ "$percent" -gt 100 ]; then
        percent=100
    fi
    echo "$percent"
}

#
# Prints "<memory_percent> <memory_used_gb> <memory_total_gb> <swap_percent> <swap_used_gb> <swap_total_gb>".
#
# Memory used is total minus available, not total minus free: free excludes the cache the kernel will
# hand back on demand, which would report a healthy machine as nearly full.
#
sample_memory() {
    awk '
        /^MemTotal:/     { total = $2 }
        /^MemAvailable:/ { available = $2 }
        /^SwapTotal:/    { swap_total = $2 }
        /^SwapFree:/     { swap_free = $2 }
        END {
            used = total - available
            swap_used = swap_total - swap_free
            memory_percent = (total > 0) ? int(used * 100 / total) : 0
            swap_percent = (swap_total > 0) ? int(swap_used * 100 / swap_total) : 0
            printf "%d %.1f %.1f %d %.1f %.1f\n", \
                memory_percent, used / 1048576, total / 1048576, \
                swap_percent, swap_used / 1048576, swap_total / 1048576
        }
    ' /proc/meminfo
}

#
# Appends a value to a history array named by the caller, dropping the oldest once it is full.
# Usage: push_history <array_name> <value>
#
push_history() {
    local array_name="$1"
    local value="$2"
    local -n history_ref="$array_name"

    history_ref+=("$value")
    if [ "${#history_ref[@]}" -gt "$graph_width" ]; then
        history_ref=("${history_ref[@]:1}")
    fi
}

#
# Prints a bar graph of one history, one block per sample, oldest on the left.
# Usage: render_graph <array_name>
#
render_graph() {
    local array_name="$1"
    local -n history_ref="$array_name"
    local value index output=""

    for value in ${history_ref[@]+"${history_ref[@]}"}; do
        index=$(( value * GRAPH_BLOCK_COUNT / 101 ))
        if [ "$index" -lt 0 ]; then
            index=0
        fi
        if [ "$index" -ge "$GRAPH_BLOCK_COUNT" ]; then
            index=$(( GRAPH_BLOCK_COUNT - 1 ))
        fi
        output="$output${GRAPH_BLOCKS[$index]}"
    done
    printf '%s' "$output"
}

#
# Prints the health history as one character per sample: a green tick where every emulator was
# healthy, a red cross where one was found unhealthy, and a dim question mark where some had not been
# looked at yet and none of the ones that had was bad. This is the row that lines an emulator going
# bad up against what the machine was doing at the time, so a cross has to mean a finding and not a
# gap in what was known, and the gaps say so in the same word the table uses for them.
#
render_health_graph() {
    local value output=""

    for value in ${health_history[@]+"${health_history[@]}"}; do
        if [ "$value" = "1" ]; then
            output="$output${COLOUR_GREEN}✓${COLOUR_OFF}"
        elif [ "$value" = "2" ]; then
            output="$output${COLOUR_DIM}?${COLOUR_OFF}"
        else
            output="$output${COLOUR_RED}x${COLOUR_OFF}"
        fi
    done
    printf '%s' "$output"
}

#
# Prints the whole display, one line per line of output. Building it as text first and drawing it in
# one go is what lets the redraw overwrite exactly the lines it wrote before.
# Usage: render_display <memory_line> <swap_line> <cpu_percent> <healthy_count> <total_count> <row>...
#
render_display() {
    local memory_summary="$1"
    local swap_summary="$2"
    local cpu_percent="$3"
    local healthy_count="$4"
    local total_count="$5"
    shift 5

    local row pool serial status detail cpu memory padded_serial padded_status colour

    printf '%-*s%-*s%-*s%*s %*s  %s\n' \
        "$POOL_WIDTH" "POOL" "$SERIAL_WIDTH" "EMULATOR" "$STATUS_WIDTH" "STATUS" \
        "$CPU_WIDTH" "CPU" "$MEMORY_WIDTH" "MEM" "DETAIL"

    if [ "$#" -eq 0 ]; then
        printf '%s\n' "${COLOUR_DIM}no devices attached${COLOUR_OFF}"
    fi

    for row in "$@"; do
        IFS='|' read -r pool serial status detail cpu memory <<< "$row"

        # Padded before it is coloured, because the escape sequences are invisible on screen but do
        # count towards a printf field width, which would leave the columns ragged.
        printf -v padded_serial '%-*s%-*s' "$POOL_WIDTH" "$pool" "$SERIAL_WIDTH" "$serial"
        printf -v padded_status '%-*s' "$STATUS_WIDTH" "$status"
        # Unknown is dim rather than red. It means nobody has looked at this emulator yet, which is
        # not a finding, and colouring it as one would report trouble that has not been established.
        # Repairing is purple rather than red: it is broken, but it is broken and being dealt with,
        # which is a different thing to look at across a table.
        if [ "$status" = "Healthy" ]; then
            colour="$COLOUR_GREEN"
        elif [ "$status" = "Unknown" ]; then
            colour="$COLOUR_DIM"
        elif [ "$status" = "⟳ Repairing" ]; then
            colour="$COLOUR_PURPLE"
        else
            colour="$COLOUR_RED"
        fi

        printf '%s%s%s%s%*s %*s  %s\n' \
            "$padded_serial" "$colour" "$padded_status" "$COLOUR_OFF" \
            "$CPU_WIDTH" "$cpu" "$MEMORY_WIDTH" "$memory" "$detail"
    done

    printf '\n'
    printf 'CPU  %s %3s%%\n' "$(render_graph cpu_history)" "$cpu_percent"
    printf 'MEM  %s %s\n' "$(render_graph memory_history)" "$memory_summary"
    printf 'SWAP %s %s\n' "$(render_graph swap_history)" "$swap_summary"
    # Two spaces, not one, so the count lines up under the percentages above it. Those are printed to
    # a width of three, so a single space here left the count one column to their left.
    printf 'OK   %s  %s of %s healthy\n' "$(render_health_graph)" "$healthy_count" "$total_count"
}

#
# Draws the display over the top of the previous one. The first draw just prints; every draw after it
# walks the cursor back up over the lines it wrote last time and overwrites them, clearing each line
# to its end so a shorter line cannot leave the tail of a longer one behind.
# Usage: draw_display <same arguments as render_display>
#
draw_display() {
    local rendered line count=0

    rendered="$(render_display "$@")"

    if [ "$lines_drawn" -gt 0 ] && [ -t 1 ]; then
        printf '\033[%dA' "$lines_drawn"
    fi

    while IFS= read -r line; do
        if [ -t 1 ]; then
            printf '%s\033[K\n' "$line"
        else
            printf '%s\n' "$line"
        fi
        count=$((count + 1))
    done <<< "$rendered"

    # A display that has lost a row would leave the old last line stranded below the new one, so any
    # line the previous draw used and this one did not is blanked and counted as ours.
    while [ "$count" -lt "$lines_drawn" ]; do
        if [ -t 1 ]; then
            printf '\033[K\n'
        else
            printf '\n'
        fi
        count=$((count + 1))
    done

    lines_drawn="$count"
}

#
# Prints one timestamped line. This is the whole of the output in the default mode, so a line has to
# carry everything about the pass that is worth having in a log afterwards.
# Usage: monitor_log <words...>
#
monitor_log() {
    MONITOR_OUTPUT_SEEN="yes"
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

# Whether anything has been printed since this was last set to "no". The table redraws itself in
# place by walking the cursor back over the lines it wrote, so anything else printing in between
# leaves the old frame stranded on screen. This says whether that happened, so the display starts a
# fresh frame only when there was something to say, rather than after every pool check.
MONITOR_OUTPUT_SEEN="no"

# How many repairs of each index have failed in a row, the reading of SECONDS before which each index
# is not to be repaired again, and how many runs of failed repairs each index has had (which is what
# the wait doubles on). All keyed by pool index.
declare -A MONITOR_FAILURES=()
declare -A MONITOR_WAIT_UNTIL=()
declare -A MONITOR_WAIT_ROUNDS=()

# Whether the missing-network message has already been printed, so a monitor left running while the
# bridge is down says so once rather than on every pass.
MONITOR_NETWORK_REPORTED="no"

#
# True when no test run holds the harness lock for the given serial. Takes the lock non-blocking and
# gives it straight back, because the repair itself takes it again and holds it for the whole
# restart; this is only to tell a busy emulator from a free one without waiting on it.
#
# A machine with no flock is treated as busy. Not knowing whether a test is using an emulator is not
# a reason to restart it.
# Usage: device_lock_is_free <serial>
#
device_lock_is_free() {
    local serial="$1"
    local fd

    if ! command -v flock >/dev/null 2>&1; then
        return 1
    fi

    exec {fd}<>"$(android_device_lock_path "$serial")"
    if flock -n "$fd"; then
        exec {fd}>&-
        return 0
    fi
    exec {fd}>&-
    return 1
}

#
# Forgets everything this monitor is holding against one index: the failures counted against it, the
# wait it is serving, and how many waits it has served. Called when an index is repaired or is found
# healthy, so the next trouble it has starts from a clean slate rather than from a run of failures
# that is over.
# Usage: clear_repair_history <index>
#
clear_repair_history() {
    local index="$1"

    MONITOR_FAILURES["$index"]=0
    unset "MONITOR_WAIT_UNTIL[$index]"
    unset "MONITOR_WAIT_ROUNDS[$index]"
}

#
# Records that a repair of one index has finished, keeping the count of how many in a row have
# failed and starting a wait when a run of them has failed.
# Usage: record_repair_outcome <index> <exit_status>
#
record_repair_outcome() {
    local index="$1"
    local status="$2"
    local failures rounds wait_seconds

    if [ "$status" -eq 0 ]; then
        clear_repair_history "$index"
        return 0
    fi

    failures=$(( ${MONITOR_FAILURES[$index]:-0} + 1 ))
    MONITOR_FAILURES["$index"]="$failures"
    monitor_log "repairing pool-$index failed ($failures in a row). What it printed is in $MONITOR_REPAIR_LOG_PATH."

    if [ "$failures" -lt "$MONITOR_MAX_CONSECUTIVE_FAILURES" ]; then
        return 0
    fi

    # The wait doubles per round rather than per failure, so each round is a fresh set of attempts
    # after a longer rest, and the rounds are counted before the wait is worked out so the first one
    # is the base wait rather than half of it.
    rounds=$(( ${MONITOR_WAIT_ROUNDS[$index]:-0} + 1 ))
    MONITOR_WAIT_ROUNDS["$index"]="$rounds"

    wait_seconds="$MONITOR_BACKOFF_SECONDS"
    while [ "$rounds" -gt 1 ] && [ "$wait_seconds" -lt "$MONITOR_MAX_BACKOFF_SECONDS" ]; do
        wait_seconds=$(( wait_seconds * 2 ))
        rounds=$(( rounds - 1 ))
    done
    if [ "$wait_seconds" -gt "$MONITOR_MAX_BACKOFF_SECONDS" ]; then
        wait_seconds="$MONITOR_MAX_BACKOFF_SECONDS"
    fi

    MONITOR_WAIT_UNTIL["$index"]=$(( SECONDS + wait_seconds ))
    MONITOR_FAILURES["$index"]=0

    monitor_log "leaving pool-$index alone for $(( wait_seconds / 60 )) minute(s) after $failures failed repair(s) in a row, then trying again. Repairs fail this way when the machine is too loaded to boot an emulator inside the timeout, which passes. Everything that can be read about it follows."
    "$EMULATOR_SCRIPT" pool-diagnose "$index" 2>&1 | sed 's/^/    /' || true
}

#
# Repairs one pool index, unless a test run is using it.
#
# On a terminal the repair is started in the background and the row for that emulator turns purple in
# the table until it finishes, so the display keeps updating and the account of the repair does not
# scroll the table away. The repair's own output goes to MONITOR_REPAIR_LOG_PATH, which is where to
# look when one fails. Written to a log rather than the screen because a cold boot prints a great deal
# and none of it is worth watching go by; what is worth seeing is which emulator is being fixed, which
# the table now says.
#
# Redirected to a file, where there is no table, the repair runs in the foreground and prints as it
# goes, because that is what a log wants.
# Usage: repair_index <index> <serial or -> <reason>
#
repair_index() {
    local index="$1"
    local serial="$2"
    local reason="$3"
    local status=0

    if [ -n "$serial" ] && [ "$serial" != "-" ] && ! device_lock_is_free "$serial"; then
        monitor_log "pool-$index needs repairing ($reason), but a test run is holding $serial. Left alone."
        return 0
    fi

    if [ "$MONITOR_ON_TERMINAL" = "no" ]; then
        monitor_log "repairing pool-$index: $reason"
        "$EMULATOR_SCRIPT" pool-repair --index "$index" 2>&1 | sed 's/^/    /' || status=$?
        record_repair_outcome "$index" "$status"
        return 0
    fi

    # The pid is kept the moment the repair is started, which is what lets the loop below notice it
    # finishing and lets Ctrl-C take it down with the monitor rather than leaving it running.
    "$EMULATOR_SCRIPT" pool-repair --index "$index" >> "$MONITOR_REPAIR_LOG_PATH" 2>&1 &
    MONITOR_REPAIR_PID=$!
    MONITOR_REPAIR_INDEX="$index"
}

#
# Notices a background repair finishing and records how it went. Does nothing while one is still
# running, and nothing at all when there is none.
#
reap_repair() {
    local status=0

    if [ -z "$MONITOR_REPAIR_PID" ]; then
        return 0
    fi
    if kill -0 "$MONITOR_REPAIR_PID" 2>/dev/null; then
        return 0
    fi

    wait "$MONITOR_REPAIR_PID" || status=$?
    record_repair_outcome "$MONITOR_REPAIR_INDEX" "$status"

    MONITOR_REPAIR_PID=""
    MONITOR_REPAIR_INDEX=""
}

#
# Brings the whole pool up by calling `emulator.sh pool-up`, and says why it is doing it.
#
# The one place this script can reach a password prompt. pool-up sudo's for the bridge and the taps
# when they are not there, starts every missing emulator at once rather than one per pass, and keeps
# their data, so the app survives and no run has to reinstall.
#
# It is attempted once per outage rather than once per pass. A machine with no bridge and nobody at
# the keyboard would otherwise be asked for a password every few seconds for as long as the monitor
# runs, and every one of those attempts fails the same way.
# Usage: start_whole_pool <reason>
#
start_whole_pool() {
    local reason="$1"
    local status=0

    if [ "$MONITOR_START_ATTEMPTED" = "yes" ]; then
        return 0
    fi
    MONITOR_START_ATTEMPTED="yes"

    monitor_log "bringing the whole pool up: $reason. This runs 'emulator.sh pool-up', which asks for sudo when the bridge or the taps have to be made."
    "$EMULATOR_SCRIPT" pool-up 2>&1 | sed 's/^/    /' || status=$?

    if [ "$status" -eq 0 ]; then
        monitor_log "the pool is up."
        MONITOR_START_ATTEMPTED="no"
        MONITOR_NETWORK_REPORTED="no"
        return 0
    fi

    monitor_log "bringing the pool up failed (exit $status). It will not be tried again until the pool is back or this monitor is restarted, because a password prompt nobody is there to answer would repeat every pass."
}

#
# Forgets every emulator this run has seen that adb no longer lists, so the display stops showing it
# as Gone.
#
# Called only from a pool check that found nothing wrong. At that moment an emulator missing from adb
# is one no pool index is waiting on: a hand-testing emulator somebody shut down, or a repaired one
# that came back under a different serial. Asked of adb here and now rather than left to the display
# to do later, because "later" is what let a newly dead emulator be forgotten instead of reported.
#
forget_gone_emulators() {
    local attached serial

    if [ "${#avd_by_serial[@]}" -eq 0 ]; then
        return 0
    fi

    attached=" $(attached_devices | awk '{ print $1 }' | tr '\n' ' ')"

    for serial in "${!avd_by_serial[@]}"; do
        case "$attached" in
            *" $serial "*)
                continue
                ;;
        esac
        unset "avd_by_serial[$serial]"
        unset "cgroup_by_serial[$serial]"
        unset "row_by_serial[$serial]"
        unset "cpu_usec_by_serial[$serial]"
        unset "cpu_stamp_by_serial[$serial]"
    done
}

#
# Looks at every pool index and repairs at most one of them.
#
# One per pass, in the order the indexes come, because five cold boots at once is a large load on a
# machine that is already in trouble. Everything broken is reported whether or not it is the one
# being repaired, so a log of this says how bad the pool was at every point and not only what was
# done about it.
#
repair_pass() {
    local index serial unit uptime verdict repair reason
    local candidate="" candidate_serial="" candidate_reason=""
    local broken=0 unhealthy=0 active=0
    local oldest_index="" oldest_serial="" oldest_uptime=0

    # A repair is already running. Nothing here could act on what it found anyway, since repairs are
    # one at a time, and the emulator being fixed would read as broken on every pass in the meantime.
    if [ -n "$MONITOR_REPAIR_PID" ]; then
        return 0
    fi

    # No bridge and no taps means the pool has to be built rather than repaired, which is what
    # pool-up does and the only step that needs root.
    if ! "$EMULATOR_SCRIPT" pool-network >/dev/null 2>&1; then
        if [ "$MONITOR_NETWORK_REPORTED" = "no" ]; then
            monitor_log "the pool's network is not in place."
            "$EMULATOR_SCRIPT" pool-network 2>&1 | sed 's/^/    /' || true
            MONITOR_NETWORK_REPORTED="yes"
        fi

        start_whole_pool "the pool's network is not in place"
        return 0
    fi
    if [ "$MONITOR_NETWORK_REPORTED" = "yes" ]; then
        monitor_log "the pool's network is back."
        MONITOR_NETWORK_REPORTED="no"
    fi

    while IFS=$'\t' read -r index serial unit uptime verdict repair reason; do
        if [ -z "$index" ]; then
            continue
        fi

        if [ "$unit" = "active" ]; then
            active=$(( active + 1 ))
        fi

        if [ "$repair" = "yes" ]; then
            broken=$(( broken + 1 ))

            # Serving a wait after a run of failed repairs. Nothing is said about it here: it said
            # how long it would be when the wait started, and a pass runs every few seconds, so
            # saying it again on each of them is how three dead emulators printed for hours.
            if [ -n "${MONITOR_WAIT_UNTIL[$index]:-}" ]; then
                if [ "$SECONDS" -lt "${MONITOR_WAIT_UNTIL[$index]}" ]; then
                    continue
                fi
                unset "MONITOR_WAIT_UNTIL[$index]"
                monitor_log "the wait on pool-$index is up, so it is due for another repair."
            fi

            if [ -z "$candidate" ]; then
                candidate="$index"
                candidate_serial="$serial"
                candidate_reason="$reason"
            else
                monitor_log "index $index is broken too ($reason). It waits for a later pass: one emulator is repaired at a time."
            fi
            continue
        fi

        if [ "$verdict" != "healthy" ]; then
            unhealthy=$(( unhealthy + 1 ))
            monitor_log "index $index is $verdict and is being left alone: $reason"
            continue
        fi

        # Healthy, so the run of failures that was being waited out is over, whether this monitor's
        # last repair ended it or somebody fixed it by hand. The next trouble this index has gets a
        # full set of attempts rather than inheriting an hour-long wait from the last one.
        clear_repair_history "$index"

        # A minute's margin before a later index displaces an earlier one as the oldest. Each index's
        # reading is taken in turn and each takes a second or two, so a pool whose emulators all
        # started together reports the last one checked as marginally the oldest; without the margin
        # the recycling would always pick the highest index rather than the genuinely oldest.
        case "$uptime" in
            ''|*[!0-9]*)
                ;;
            *)
                if [ "$uptime" -gt "$(( oldest_uptime + 60 ))" ]; then
                    oldest_uptime="$uptime"
                    oldest_index="$index"
                    oldest_serial="$serial"
                fi
                ;;
        esac
    done < <("$EMULATOR_SCRIPT" pool-check)

    # An emulator running means the last start worked, whenever it was, so the next outage gets its
    # own attempt at bringing the pool up.
    if [ "$active" -gt 0 ]; then
        MONITOR_START_ATTEMPTED="no"
    fi

    # Nothing at all is running, so this is one pool-up rather than five repairs one pass apart, which
    # is both faster and kinder: pool-up starts them together and keeps their data, so the app
    # survives and the next run has nothing to reinstall.
    if [ "$active" -eq 0 ]; then
        start_whole_pool "no pool emulator is running"
        return 0
    fi

    if [ -n "$candidate" ]; then
        repair_index "$candidate" "$candidate_serial" "$candidate_reason"
        return 0
    fi

    # Every index accounted for and well, so an emulator the display is still showing as Gone is one
    # that is not coming back and that nothing is waiting on: it can stop taking up a row.
    if [ "$broken" -eq 0 ] && [ "$unhealthy" -eq 0 ]; then
        forget_gone_emulators
    fi

    # Nothing is broken, so this is the moment to deal with age. The emulators that died had been up
    # 23.5 hours holding 6.6 to 6.7GB each plus up to 2GB of swap, and a cold boot costs nothing when
    # nothing is waiting on it. Only with every other index healthy, and only when no test is using
    # it, so recycling can never be what takes the pool below what a run needs.
    if [ "$broken" -eq 0 ] && [ "$unhealthy" -eq 0 ] && [ -n "$oldest_index" ] \
        && [ "$oldest_uptime" -gt "$MONITOR_MAX_UPTIME_SECONDS" ]; then
        repair_index "$oldest_index" "$oldest_serial" \
            "it has been up $(( oldest_uptime / 3600 ))h, past the $(( MONITOR_MAX_UPTIME_SECONDS / 3600 ))h a pool emulator is recycled after, and every other index is healthy"
    fi
}

#
# Checks every attached emulator and prints one line saying how they and the machine are. This is the
# whole of a pass in the default mode.
#
line_pass() {
    local attached_lines=() line serial adb_state result status detail
    local healthy=0 total=0 summary=""
    local cpu_percent memory_percent memory_used memory_total swap_percent swap_used swap_total

    mapfile -t attached_lines < <(attached_devices)

    for line in ${attached_lines[@]+"${attached_lines[@]}"}; do
        serial="${line%% *}"
        adb_state="${line#* }"
        result="$(health_of "$serial" "$adb_state")"
        status="${result%%|*}"
        detail="${result#*|}"
        total=$(( total + 1 ))

        # Which emulator this is, in the naming the rest of the pool uses. Asked once per serial and
        # kept, because it cannot change while an emulator is running and a log full of adb serials
        # alone cannot be read against a repair message that talks about indexes.
        if [ -z "${avd_by_serial[$serial]:-}" ]; then
            avd_by_serial["$serial"]="$(timeout "$ADB_TIMEOUT_SECONDS" adb -s "$serial" emu avd name </dev/null 2>/dev/null | head -1 | tr -d '\r')"
        fi

        if [ "$status" = "Healthy" ]; then
            healthy=$(( healthy + 1 ))
        fi
        summary="$summary $(pool_label_for_serial "$serial")/$serial=$status($detail)"
    done

    cpu_percent="$(sample_cpu_percent)"
    read -r memory_percent memory_used memory_total swap_percent swap_used swap_total < <(sample_memory)

    monitor_log "$healthy of $total healthy | cpu ${cpu_percent}% mem ${memory_percent}% (${memory_used}/${memory_total} GB) swap ${swap_percent}% (${swap_used}/${swap_total} GB) |${summary:- no devices attached}"
}

#
# The loop used when this is not on a terminal: one line per pass, then a look at the pool.
#
line_loop() {
    while true; do
        line_pass
        repair_pass
        sleep "$MONITOR_INTERVAL_SECONDS"
    done
}

trap restore_terminal INT TERM

if ! command -v adb >/dev/null 2>&1; then
    echo "ERROR: adb not found on PATH, so emulator health cannot be read." >&2
    exit 1
fi

# One monitor per machine. Two of them would fight over the same emulators, each restarting one the
# other was waiting on, and the pool would never settle.
if ! command -v flock >/dev/null 2>&1; then
    echo "ERROR: flock is not installed, so it cannot be established that this is the only monitor" >&2
    echo "on this machine. Two monitors would fight over the same emulators, so refusing to start." >&2
    exit 1
fi
exec {monitor_lock_fd}<>"$MONITOR_LOCK_PATH"
if ! flock -n "$monitor_lock_fd"; then
    echo "ERROR: a monitor is already running on this machine (it holds $MONITOR_LOCK_PATH)." >&2
    echo "Stop that one first. To read the pool without starting a second monitor:" >&2
    echo "  bun run emu:and:pool:status" >&2
    echo "  bun run --filter=android-frontend emu:pool:diagnose" >&2
    exit 1
fi

# Primes the CPU counters, so the first reading reports the change since now rather than the average
# since the machine booted.
sample_cpu_percent >/dev/null

rows=()
healthy_count=0
unknown_count=0
total_count=0
sample_index=0
health_turn=0

# The display picks itself. Redirected to a file, one timestamped line per pass; on a terminal, the
# table and graphs below, which redraw in place and would be unreadable in a log.
if [ ! -t 1 ]; then
    line_loop
    exit 0
fi

printf '\033[?25l'

# Set an interval back, so the first pass looks at the pool straight away rather than after the first
# interval of watching.
last_repair_at=$(( SECONDS - MONITOR_INTERVAL_SECONDS ))

while true; do
    if [ $(( sample_index % HEALTH_EVERY_SAMPLES )) -eq 0 ]; then
        # One emulator is checked per turn, taken in rotation, rather than all of them at once.
        #
        # A sick emulator is the expensive one to ask: it stays listed as a device and accepts the
        # connection while answering nothing, so every call to it costs the full timeout. Checking
        # all five in a row meant one stuck emulator held up the whole frame, and with several stuck
        # the first frame never finished at all, so the display showed nothing precisely when it was
        # most worth watching. In rotation a stuck emulator delays its own row and nothing else, and
        # the graphs keep moving throughout.
        mapfile -t attached_lines < <(attached_devices)

        attached_serials=()
        for line in ${attached_lines[@]+"${attached_lines[@]}"}; do
            attached_serials+=("${line%% *}")
        done

        if [ "${#attached_serials[@]}" -gt 0 ]; then
            turn_index=$(( health_turn % ${#attached_serials[@]} ))
            serial="${attached_serials[$turn_index]}"
            adb_state="${attached_lines[$turn_index]#* }"

            result="$(health_of "$serial" "$adb_state")"

            # The AVD name and its control group are found once per emulator and kept, because
            # neither changes while it is running and both cost more than reading the figures does.
            if [ -z "${avd_by_serial[$serial]:-}" ]; then
                avd_by_serial["$serial"]="$(timeout "$ADB_TIMEOUT_SECONDS" adb -s "$serial" emu avd name </dev/null 2>/dev/null | head -1 | tr -d '\r')"
            fi
            if [ -z "${cgroup_by_serial[$serial]:-}" ] && [ -n "${avd_by_serial[$serial]:-}" ]; then
                cgroup_by_serial["$serial"]="$(cgroup_dir_for_avd "${avd_by_serial[$serial]}")"
            fi
            # Called directly, not through a command substitution, so its saved readings survive to
            # the next sample and CPU can be worked out from the change between them.
            emulator_usage "$serial"
            emulator_cpu="$emulator_cpu_result"
            emulator_memory="$emulator_memory_result"
            if [ "$emulator_cpu" != "?" ]; then
                emulator_cpu="$emulator_cpu%"
            fi

            row_by_serial["$serial"]="$result|$emulator_cpu|$emulator_memory"
            health_turn=$(( health_turn + 1 ))
        fi

        # The table is rebuilt from what is attached now, so an emulator that has gone leaves the
        # display rather than lingering on its last known reading. One not yet reached in the
        # rotation says so instead of claiming a state nobody has looked at.
        rows=()
        healthy_count=0
        unknown_count=0
        total_count=0
        for serial in ${attached_serials[@]+"${attached_serials[@]}"}; do
            rows+=("$(pool_label_for_serial "$serial")|$serial|${row_by_serial[$serial]:-Unknown|not checked yet|?|?}")
            total_count=$(( total_count + 1 ))
            case "${row_by_serial[$serial]:-}" in
                Healthy\|*) healthy_count=$(( healthy_count + 1 )) ;;
                ''|Unknown\|*) unknown_count=$(( unknown_count + 1 )) ;;
            esac
        done

        # An emulator that crashes hard leaves adb's list altogether, and a row that simply vanishes
        # says nothing at all: the worst thing that can happen to an emulator was the one event the
        # display did not report. Every serial this run has seen is remembered, so one that goes is
        # shown as Gone and counted as unhealthy, which is also what puts the cross in the OK row.
        #
        # forget_gone_emulators is what drops those rows again, and it runs from a pool check rather
        # than from here. This used to be a flag that check set for the display to act on later, and
        # with a pass every five seconds the flag was nearly always set: an emulator that died a
        # moment after a clean check was forgotten on sight instead of being shown as Gone.
        # The size is checked rather than the usual ${array[@]+"${array[@]}"} guard, because that form
        # cannot be combined with ${!array[@]}: bash reads the ! as an indirect reference and tries to
        # use the array's first value as a variable name, which fails with "invalid variable name".
        if [ "${#avd_by_serial[@]}" -gt 0 ]; then
        for serial in "${!avd_by_serial[@]}"; do
            case " ${attached_serials[*]-} " in
                *" $serial "*)
                    continue
                    ;;
            esac

            rows+=("$(pool_label_for_serial "$serial")|$serial|Gone|no longer listed by adb|?|?")
            total_count=$(( total_count + 1 ))
        done
        fi

        # The emulator being repaired says so in its own row, in purple, which is the whole of what
        # the display shows about a repair. Its own output goes to a log instead: a cold boot prints
        # a great deal, none of it worth watching go past, and printing it here pushed the table off
        # the screen and left a copy of it stranded above.
        if [ -n "$MONITOR_REPAIR_INDEX" ]; then
            repairing_row_found="no"
            rebuilt_rows=()
            for row in ${rows[@]+"${rows[@]}"}; do
                case "$row" in
                    "pool-$MONITOR_REPAIR_INDEX|"*)
                        repairing_serial="${row#*|}"
                        repairing_serial="${repairing_serial%%|*}"
                        rebuilt_rows+=("pool-$MONITOR_REPAIR_INDEX|$repairing_serial|⟳ Repairing|restarting it and waiting for the bridge|?|?")
                        repairing_row_found="yes"
                        ;;
                    *)
                        rebuilt_rows+=("$row")
                        ;;
                esac
            done

            # An index that was already gone before this monitor ever saw it has no row to change, so
            # it gets one: an emulator being restarted is exactly what somebody watching wants to see.
            if [ "$repairing_row_found" = "no" ]; then
                rebuilt_rows+=("pool-$MONITOR_REPAIR_INDEX|-|⟳ Repairing|restarting it and waiting for the bridge|?|?")
                total_count=$(( total_count + 1 ))
            fi

            rows=(${rebuilt_rows[@]+"${rebuilt_rows[@]}"})
        fi
    fi
    sample_index=$(( sample_index + 1 ))

    cpu_percent="$(sample_cpu_percent)"
    read -r memory_percent memory_used memory_total swap_percent swap_used swap_total < <(sample_memory)

    push_history cpu_history "$cpu_percent"
    push_history memory_history "$memory_percent"
    push_history swap_history "$swap_percent"
    # Three states, not two. Emulators are checked in rotation, so for the first few seconds of a run
    # most rows have not been looked at yet, and recording those samples as unhealthy drew a row of
    # red crosses for a pool that was fine. A cross now means an emulator was found unhealthy.
    if [ "$total_count" -gt 0 ] && [ "$healthy_count" -eq "$total_count" ]; then
        push_history health_history 1
    elif [ "$total_count" -gt 0 ] && [ "$(( healthy_count + unknown_count ))" -eq "$total_count" ]; then
        push_history health_history 2
    else
        push_history health_history 0
    fi

    draw_display \
        "$(printf '%3s%% %s/%s GB' "$memory_percent" "$memory_used" "$memory_total")" \
        "$(printf '%3s%% %s/%s GB' "$swap_percent" "$swap_used" "$swap_total")" \
        "$cpu_percent" \
        "$healthy_count" \
        "$total_count" \
        ${rows[@]+"${rows[@]}"}

    # A pool check that finds nothing to do prints nothing, and the display carries on redrawing in
    # place. One that has something to say prints it under the table, and the next frame then starts
    # a fresh table below that, so the account of what was done stays on screen rather than being
    # overwritten.
    reap_repair

    if [ $(( SECONDS - last_repair_at )) -ge "$MONITOR_INTERVAL_SECONDS" ]; then
        MONITOR_OUTPUT_SEEN="no"
        repair_pass
        last_repair_at="$SECONDS"
        if [ "$MONITOR_OUTPUT_SEEN" = "yes" ]; then
            lines_drawn=0
        fi
    fi

    sleep "$SAMPLE_SECONDS"
done
