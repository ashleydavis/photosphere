#!/usr/bin/env bash
# Watches every attached emulator and keeps a table of their health on screen, with live CPU, memory
# and swap graphs beneath it, rewriting the whole thing in place so the terminal holds one display
# rather than a growing pile of them.
#
# The point of the graphs sitting under the table is correlation: when an emulator goes red, the
# history to the left of that moment shows what the machine was doing in the run-up to it. The bottom
# row marks each sample where anything was unhealthy, so a glance lines the two up.
#
# Strictly read-only. It asks adb what it can see, asks each emulator for its address, and reads
# /proc for the machine's own figures. It never starts, stops, reboots or reconfigures anything.
#
# Healthy means all three of: adb lists the device as `device` rather than offline or unauthorized,
# the guest reports sys.boot_completed, and wlan0 holds a 192.168.55.x address. That last one is the
# same condition the smoke tests require, so a row reading Healthy means the tests can use it.
#
# Usage:
#   apps/android-frontend/scripts/emulator-health.sh        # bun run emu:and:health
#
# Press Ctrl-C to stop.
set -uo pipefail

# How long between frames. One second, because this is what sets the graphs' resolution: a sample per
# second is fine enough to show a spike without making the history cover only a few moments.
SAMPLE_SECONDS=1

# How many samples between emulator health checks. The graphs come from /proc and cost nothing, but a
# health check is several adb calls per emulator, and adb is already busy serving the test run. Every
# third sample keeps that load down while still noticing an emulator within a few seconds.
HEALTH_EVERY_SAMPLES=3

# How long any single adb call may take before it is abandoned. An adb that wedges would otherwise
# hang the whole watch, and a display frozen on stale rows is worse than one that says so.
ADB_TIMEOUT_SECONDS=8

# Column widths for the table. The serial column fits "emulator-5554" with room to spare, and the
# status column fits "Unhealthy" plus a gap.
SERIAL_WIDTH=16
STATUS_WIDTH=12

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
    COLOUR_DIM=$'\033[0;90m'
    COLOUR_OFF=$'\033[0m'
else
    COLOUR_GREEN=""
    COLOUR_RED=""
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
# Usage: health_of <serial> <adb_state>
#
health_of() {
    local serial="$1"
    local adb_state="$2"
    local booted address

    if [ "$adb_state" != "device" ]; then
        echo "Unhealthy|adb says $adb_state"
        return 0
    fi

    # Every adb call reads from /dev/null. `adb shell` consumes its standard input, and these run
    # inside a loop whose standard input is the list of devices, so without this the first emulator
    # checked would swallow the rest of the list and the table would show one row.
    # An empty answer means the emulator did not answer, which is its own condition and not the same
    # as any of the states below. An emulator thrashing on memory stays listed by adb as a device and
    # accepts the connection while answering nothing, and calling that "still booting" or "off the
    # lan bridge" states something definite that has not been established. It says which it is.
    booted="$(timeout "$ADB_TIMEOUT_SECONDS" adb -s "$serial" shell getprop sys.boot_completed </dev/null 2>/dev/null | tr -d '\r' | head -1)"
    if [ -z "$booted" ]; then
        echo "Unhealthy|not answering adb"
        return 0
    fi
    if [ "$booted" != "1" ]; then
        echo "Unhealthy|still booting"
        return 0
    fi

    # `ip addr show`, not `ip -4 addr show`. The -4 form prints nothing at all when the interface has
    # no IPv4 address, which is indistinguishable from the command having failed. Without the flag
    # the link line is always printed, so an empty result means only one thing, and the line also
    # carries NO-CARRIER, which says the wifi dropped rather than merely lost its lease.
    wlan_output="$(timeout "$ADB_TIMEOUT_SECONDS" adb -s "$serial" shell ip addr show wlan0 </dev/null 2>/dev/null)"
    if [ -z "$wlan_output" ]; then
        echo "Unhealthy|not answering adb"
        return 0
    fi

    address="$(printf '%s\n' "$wlan_output" | grep -o 'inet 192\.168\.55\.[0-9]*' | head -1)"
    address="${address#inet }"
    if [ -z "$address" ]; then
        if printf '%s\n' "$wlan_output" | grep -q 'NO-CARRIER'; then
            echo "Unhealthy|off the lan bridge, wifi down"
        else
            echo "Unhealthy|off the lan bridge, no address"
        fi
        return 0
    fi

    echo "Healthy|$address"
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
# Prints the health history as one character per sample: a dim dot where everything was healthy and a
# red cross where anything was not. This is the row that lines an emulator going bad up against what
# the machine was doing at the time.
#
render_health_graph() {
    local value output=""

    for value in ${health_history[@]+"${health_history[@]}"}; do
        if [ "$value" = "1" ]; then
            output="$output${COLOUR_DIM}.${COLOUR_OFF}"
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

    local row serial status detail cpu memory padded_serial padded_status colour

    printf '%-*s%-*s%*s %*s  %s\n' \
        "$SERIAL_WIDTH" "EMULATOR" "$STATUS_WIDTH" "STATUS" \
        "$CPU_WIDTH" "CPU" "$MEMORY_WIDTH" "MEM" "DETAIL"

    if [ "$#" -eq 0 ]; then
        printf '%s\n' "${COLOUR_DIM}no devices attached${COLOUR_OFF}"
    fi

    for row in "$@"; do
        IFS='|' read -r serial status detail cpu memory <<< "$row"

        # Padded before it is coloured, because the escape sequences are invisible on screen but do
        # count towards a printf field width, which would leave the columns ragged.
        printf -v padded_serial '%-*s' "$SERIAL_WIDTH" "$serial"
        printf -v padded_status '%-*s' "$STATUS_WIDTH" "$status"
        # Unknown is dim rather than red. It means nobody has looked at this emulator yet, which is
        # not a finding, and colouring it as one would report trouble that has not been established.
        if [ "$status" = "Healthy" ]; then
            colour="$COLOUR_GREEN"
        elif [ "$status" = "Unknown" ]; then
            colour="$COLOUR_DIM"
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

trap restore_terminal INT TERM

if [ -t 1 ]; then
    printf '\033[?25l'
fi

if ! command -v adb >/dev/null 2>&1; then
    echo "ERROR: adb not found on PATH, so emulator health cannot be read." >&2
    exit 1
fi

# Primes the CPU counters, so the first frame reports the change over one sample rather than the
# average since boot.
sample_cpu_percent >/dev/null

rows=()
healthy_count=0
total_count=0
sample_index=0
health_turn=0

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
        total_count=0
        for serial in ${attached_serials[@]+"${attached_serials[@]}"}; do
            rows+=("$serial|${row_by_serial[$serial]:-Unknown|not checked yet|?|?}")
            total_count=$(( total_count + 1 ))
            case "${row_by_serial[$serial]:-}" in
                Healthy\|*) healthy_count=$(( healthy_count + 1 )) ;;
            esac
        done
    fi
    sample_index=$(( sample_index + 1 ))

    cpu_percent="$(sample_cpu_percent)"
    read -r memory_percent memory_used memory_total swap_percent swap_used swap_total < <(sample_memory)

    push_history cpu_history "$cpu_percent"
    push_history memory_history "$memory_percent"
    push_history swap_history "$swap_percent"
    if [ "$total_count" -gt 0 ] && [ "$healthy_count" -eq "$total_count" ]; then
        push_history health_history 1
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

    sleep "$SAMPLE_SECONDS"
done
