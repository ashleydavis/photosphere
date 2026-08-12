#!/usr/bin/env bash
# Connects the Android emulator to a real layer-2 network segment that this host is also on, so LAN
# sharing works between the Electron app on the host and the Photosphere app in the emulator.
#
# Why this is needed:
# By default the emulator runs behind QEMU's user-mode NAT (the 10.0.2.x network). That network is
# deliberately isolated: the guest can reach out through the host, but UDP broadcast never leaves the
# emulator, and the host cannot open a connection back to the guest. LAN sharing depends on both. The
# receiver broadcasts "PSIE_RECV:<port>:<codeHash>:<fingerprint>" to 255.255.255.255:54321, and the
# sender, on hearing it, opens an HTTPS connection back to whatever address the broadcast arrived
# from. The codeHash field carries a hash of the pairing code so a sender ignores a receiver from
# another session; without it a sender took whichever receiver announced first, which failed the
# LAN-share tests intermittently. Under
# user-mode NAT the broadcast is never heard, so the receiver waits its full 60 seconds and reports
# "No sender connected within 60 seconds".
#
# What this sets up instead:
# A private bridge (a virtual layer-2 switch in the host kernel) with two things plugged into it: the
# host itself, and a tap interface that the emulator attaches its virtual wifi to. Because both ends
# are ports on one bridge, a broadcast frame from the guest is flooded to every port including the
# host's, and the host can address the guest directly. That is a genuine network segment, so
# discovery and the HTTPS transfer both behave exactly as they do between two real machines.
#
# This deliberately does NOT bridge your physical NIC. It does not need to: the emulator runs on this
# host, so a private segment shared with the host is enough, and it avoids any risk of dropping your
# real network. The guest still reaches the internet, via NAT through the host's uplink (see below).
#
# Examples (run as your user; up/down sudo only for the bridge, or use the bun scripts):
#   apps/android-frontend/scripts/emulator.sh up        # bun run emu:and:up
#   apps/android-frontend/scripts/emulator.sh status
#   apps/android-frontend/scripts/emulator.sh restart    # bun run emu:and:restart
#   apps/android-frontend/scripts/emulator.sh down       # bun run emu:and:down
set -euo pipefail

# Name of the bridge (the virtual switch). Prefixed so it is obvious what created it.
BRIDGE_NAME="br-psphere"

# The tap and AVD names, how many emulators the pool has, and the harness's device lock path, shared
# with the smoke-test harness and the run script. Sourced rather than repeated, so a rename cannot
# leave one side looking for an interface or an AVD the other never creates. See emulator-config.sh
# for what each one is for.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/emulator-config.sh"

# The readings that say whether an emulator is healthy, shared with scripts/android-pool-status.sh
# and the pool monitor so all three judge an emulator the same way. See emulator-status-lib.sh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/emulator-status-lib.sh"

# kill_process_tree, for the one case systemd cannot cover: an emulator process that outlived its
# unit. Never a match on a command line; only pids read from the AVD's own lock file are passed to it.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../scripts/lib/process-control.sh"

#
# Prints the tap interface name for the single emulator.
#
netcard_name() {
    echo "$NETCARD_PREFIX-0"
}

#
# Prints the tap interface name for the given pool instance index.
#
pool_netcard_name() {
    echo "$POOL_NETCARD_PREFIX-$1"
}

#
# Prints the AVD name for the given pool instance index.
#
pool_avd_name() {
    echo "$POOL_AVD_PREFIX-$1"
}

#
# Prints the systemd user unit name for the given pool instance index.
#
# One definition, used by the code that starts a pool emulator and by the code that stops and
# diagnoses one, so the two cannot disagree about what a unit is called. POOL_UNIT_GLOB above matches
# every name this prints.
#
pool_unit_name() {
    echo "psphere-emu-pool-$1"
}

#
# Prints the path of the log one emulator's unit writes to, for the given log suffix ("single", or
# "pool-<index>"). One definition, so the code that points a unit at a log and the code that reads
# that log back cannot look at different files.
#
pool_log_path() {
    echo "/tmp/psphere-emulator-$1.log"
}

#
# Prints the directory holding the AVDs, honouring ANDROID_AVD_HOME.
#
avd_home() {
    echo "${ANDROID_AVD_HOME:-$HOME/.android/avd}"
}

# The host's address on the private segment. This is what the guest sees traffic coming from, and
# what it uses as its default gateway.
BRIDGE_ADDRESS="192.168.55.1"

# Prefix length and matching subnet for the private segment. 192.168.55.0/24 is used because it is
# unlikely to collide with a real home or office LAN.
BRIDGE_PREFIX="24"
BRIDGE_SUBNET="192.168.55.0/24"

# The pool dnsmasq hands out to the guest.
DHCP_RANGE_START="192.168.55.50"
DHCP_RANGE_END="192.168.55.150"

# DNS server handed to the guest over DHCP. Override with GUEST_DNS if you would rather it used your
# own resolver. It has to be something the guest can reach through the NAT, so a public resolver is
# the safe default rather than anything host-local.
GUEST_DNS="${GUEST_DNS:-1.1.1.1}"

# Where the DHCP server records its pid and writes its log, so `down` can stop the right process and
# you have somewhere to look when the guest fails to get an address.
DNSMASQ_PID_FILE="/run/psphere-emulator-dnsmasq.pid"
DNSMASQ_LOG_FILE="/tmp/psphere-emulator-dnsmasq.log"

# Records what net.ipv4.ip_forward was set to before `up` touched it, so `down` can put it back
# rather than leaving your host acting as a router. Lives in /run, which is cleared on reboot, which
# is fine because the kernel setting it describes is itself reset on reboot.
IP_FORWARD_STATE_FILE="/run/psphere-emulator-ip-forward.orig"

# The user that will own the tap interface. The emulator runs unprivileged and can only open a tap it
# owns, so this must be your login user, not root. SUDO_USER is set to the real user when the script
# is run under sudo, which is the normal case here.
TARGET_USER="${SUDO_USER:-$(id -un)}"

# The systemd user slice every emulator is started inside, the copy of its unit file kept next to this
# script, and where that unit has to be installed for the user manager to read it.
#
# A "slice" is a named group of processes that systemd and the kernel treat as one thing for resource
# limits, so a memory limit on the slice applies to everything in it added together rather than to any
# one process. psphere-pool.slice, next to this script, is where those limits are written and is
# commented at length; read that file for the numbers and the reasoning behind them.
#
# The slice is what bounds the pool. Each emulator also carries its own limit, but per-emulator limits
# alone bound nothing, because five of them within their individual limits still add up to more than
# the machine has. Without this, a test run was able to exhaust both the machine's memory and all of
# its swap, five emulators accounting for close to 30GB of it, and systemd-oomd answered by killing
# the whole terminal's cgroup rather than any one emulator, taking every shell in it with it.
#
# Note that the slice would still exist without its unit file, because systemd creates a slice named
# by --slice implicitly, but it would carry no limits whatsoever. That is why ensure_pool_slice runs
# before the first emulator starts.
POOL_SLICE="psphere-pool.slice"
POOL_SLICE_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$POOL_SLICE"
POOL_SLICE_INSTALL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

# Matches every transient unit the pool starts, whatever index it carries.
#
# A glob rather than a loop over PHOTOSPHERE_EMULATOR_COUNT, because the count can differ between the
# run that started the pool and the run stopping it: raising it from 3 to 10 and restarting must
# still account for the three that are actually up, and a loop over the new count would look at the
# wrong set.
POOL_UNIT_GLOB="psphere-emu-pool-*"

# The size of an AVD's data partition, written into config.ini and read by the emulator.
#
# This was 6G, and all five pool AVDs reached it: each one held a userdata-qemu.img.qcow2 of exactly
# 6,442,909,696 bytes, which is the 6G limit to the byte. A full data partition makes the package
# manager refuse an install with INSTALL_FAILED_INSUFFICIENT_STORAGE, and a suite that does not notice
# carries on testing whichever build was already on the device.
#
# The size only takes effect on an AVD whose userdata is created fresh, because the partition is sized
# when userdata-qemu.img is first created. Raising this number does nothing to an emulator that
# already has one; that is what the -wipe-data on pool-restart is for.
AVD_DATA_PARTITION_SIZE="12G"

# How long to wait for systemd to release those unit names after their emulators have gone. Seconds,
# because the wait is normally a moment; it is generous only so that a loaded machine is not failed
# for being slow.
POOL_UNIT_RELEASE_TIMEOUT_SECONDS=60

# How long `systemctl stop` is given for one pool emulator before it is escalated to SIGKILL, and how
# long the SIGKILL is then given.
#
# Bounded because an unbounded stop is what a recovery cannot afford. On 2026-08-09 a unit sat in
# stop-sigterm and `systemctl stop` blocked on it for two minutes with nothing to say why, during an
# incident where five emulators were already down.
POOL_STOP_TIMEOUT_SECONDS=30
POOL_KILL_TIMEOUT_SECONDS=15

# How long a pool emulator is left alone after its unit went active before pool-repair will judge it
# broken. A cold boot takes well over a minute, and an emulator part way through one looks exactly
# like a broken one: no adb device, or a device with no address yet.
POOL_REPAIR_GRACE_SECONDS="${POOL_REPAIR_GRACE_SECONDS:-90}"

# How long pool-repair waits for an emulator it restarted to reach the LAN bridge before calling the
# repair failed. Generous, because this is a cold boot with -wipe-data on a machine that is usually
# busy: pool-up allows 600s for a whole pool, and this is one emulator's share of that with room.
POOL_REPAIR_BOOT_TIMEOUT_SECONDS="${POOL_REPAIR_BOOT_TIMEOUT_SECONDS:-420}"

# Exit status stop_pool_emulator and repair_pool_index use to say an emulator was left alone because
# a test run holds its lock. Distinct from a failure, because nothing went wrong and nothing was
# changed; the caller reports it and moves on to the next index.
POOL_REPAIR_SKIPPED_STATUS=2

#
# True when the DHCP server we started is still alive.
#
# Checks /proc rather than `kill -0` because dnsmasq drops privileges to `nobody` immediately after
# starting. `kill -0` from your login user against a `nobody`-owned process fails with EPERM, which
# would report a perfectly healthy DHCP server as stopped. /proc does not care who owns the process.
#
dnsmasq_running() {
    if [ ! -f "$DNSMASQ_PID_FILE" ]; then
        return 1
    fi

    local pid
    pid="$(cat "$DNSMASQ_PID_FILE" 2>/dev/null)"
    if [ -z "$pid" ]; then
        return 1
    fi

    [ -d "/proc/$pid" ]
}

#
# Prints the path to adb, which is frequently not on PATH even with the SDK installed. Falls back to
# the standard SDK location so `status` can still report the guest's address. Prints nothing when it
# cannot be found.
#
adb_path() {
    if command -v adb >/dev/null 2>&1; then
        command -v adb
        return
    fi

    local candidate="${ANDROID_HOME:-${HOME}/Android/Sdk}/platform-tools/adb"
    if [ -x "$candidate" ]; then
        echo "$candidate"
    fi

    # Always succeed. Returning the `if` test's exit status would abort the whole script under
    # `set -e` at the caller's `adb="$(adb_path)"`, purely because adb is not installed.
    return 0
}

#
# Fails with a clear message when not running as root. Creating bridges and tap interfaces, and
# binding a DHCP server, all require it.
#
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: this must run as root (network interfaces require it). Try: sudo $0 $*" >&2
        exit 1
    fi
}

#
# Fails with a clear message when a required command is missing, rather than part way through setup.
#
require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: '$1' is not installed. $2" >&2
        exit 1
    fi
}

#
# Returns the interface carrying the host's default route, used as the uplink to NAT the guest out
# through. Detected rather than hardcoded so this works on any machine.
#
uplink_interface() {
    ip route show default | awk '/default/ { print $5; exit }'
}

#
# Brings the LAN bridge up (privileged). Internal: invoked with sudo by `cmd_up`. Safe to re-run:
# every step checks for the state it wants before creating it, so running this twice is not an error.
#
bridge_up() {
    require_root "__bridge-up"
    require_command ip "Install iproute2."
    require_command dnsmasq "Install it with your package manager (for example: sudo apt install dnsmasq)."

    # The tap driver backs the virtual NIC the emulator attaches to. It is usually autoloaded, but not
    # on every kernel, and the failure without it is an unhelpful permissions error from the emulator.
    modprobe tun 2>/dev/null || true

    # The bridge is the virtual switch. Everything else here plugs into it.
    if ! ip link show "$BRIDGE_NAME" >/dev/null 2>&1; then
        ip link add "$BRIDGE_NAME" type bridge
    fi

    # Turn off spanning tree and zero the forward delay. STP holds a newly added port in listening and
    # learning states for roughly 30 seconds before it will pass traffic, which would mean the guest
    # silently getting no DHCP reply on every boot. There is no loop to protect against on a private
    # bridge with one guest, so STP is pure startup latency.
    ip link set "$BRIDGE_NAME" type bridge stp_state 0 forward_delay 0

    # Give the bridge an address. This is the host's own port on the segment: the address the Electron
    # app's UDP socket receives broadcasts on and its HTTPS client connects out from.
    if ! ip addr show dev "$BRIDGE_NAME" | grep -q "inet $BRIDGE_ADDRESS/$BRIDGE_PREFIX"; then
        ip addr add "$BRIDGE_ADDRESS/$BRIDGE_PREFIX" dev "$BRIDGE_NAME"
    fi

    ip link set "$BRIDGE_NAME" up

    # Create the taps named in PSPHERE_TAPS: virtual NICs whose wire is a file descriptor. The
    # emulator opens one and the guest's ethernet frames come out on the bridge. Owned by your user
    # because the emulator is not root and can only open a tap it owns. One per emulator, because
    # -wifi-tap binds an emulator to a tap at launch and two emulators cannot share one.
    local netcard
    for netcard in $PSPHERE_TAPS; do
        if ! ip link show "$netcard" >/dev/null 2>&1; then
            ip tuntap add dev "$netcard" mode tap user "$TARGET_USER"
        fi

        # Plug the tap into the bridge and bring it up. Until it has a master it is an unconnected NIC.
        ip link set "$netcard" master "$BRIDGE_NAME"
        ip link set "$netcard" up
    done

    # Serve DHCP. Android runs a DHCP client on wlan0 the moment it associates with the emulator's
    # virtual access point, and with nothing answering on this segment it never gets an address and
    # the interface stays unusable.
    #
    # --port=0 turns off dnsmasq's DNS server. We only want DHCP, and leaving DNS on means trying to
    #   bind port 53, which commonly fails because systemd-resolved already holds it.
    # --bind-interfaces keeps dnsmasq on this bridge only, rather than listening broadly.
    # --except-interface=lo keeps it off loopback for the same reason.
    # option:router points the guest's default route at the host, which is what makes the NAT below
    #   reachable.
    if dnsmasq_running; then
        echo "DHCP server already running (pid $(cat "$DNSMASQ_PID_FILE"))."
    else
        rm -f "$DNSMASQ_PID_FILE"

        # Also clear any log left by a previous run. dnsmasq drops privileges and so leaves the log
        # owned by `nobody`, while /tmp is root-owned, world-writable and sticky. Under
        # fs.protected_regular (2 on current Ubuntu) the kernel refuses to let root open an existing
        # file in such a directory when it is owned by neither root nor the directory's owner, so the
        # next start dies with "cannot open log ...: Permission denied". Removing it first means
        # dnsmasq always creates the log fresh and that can never happen. Safe here because this
        # branch only runs when dnsmasq is not already running.
        rm -f "$DNSMASQ_LOG_FILE"

        dnsmasq \
            --interface="$BRIDGE_NAME" \
            --bind-interfaces \
            --except-interface=lo \
            --port=0 \
            --dhcp-range="$DHCP_RANGE_START,$DHCP_RANGE_END,12h" \
            --dhcp-option=option:router,"$BRIDGE_ADDRESS" \
            --dhcp-option=option:dns-server,"$GUEST_DNS" \
            --pid-file="$DNSMASQ_PID_FILE" \
            --log-facility="$DNSMASQ_LOG_FILE"

        # dnsmasq drops privileges to `nobody` and creates its log mode 0660, owned by nobody, which
        # your login user cannot read. Loosen it, otherwise the log this script points you at during
        # troubleshooting needs sudo just to open.
        chmod 0644 "$DNSMASQ_LOG_FILE" 2>/dev/null || true

        echo "DHCP server started, logging to $DNSMASQ_LOG_FILE"
    fi

    # Give the guest internet by routing it out through the host's uplink. Not required for LAN
    # sharing itself, but an emulator with no internet is painful to actually use, and Android will
    # flag the network as unvalidated without it.
    local uplink
    uplink="$(uplink_interface)"
    if [ -n "$uplink" ] && command -v iptables >/dev/null 2>&1; then
        # Forwarding is off by default on most distros; without it the host will not route the
        # guest's packets at all. Save the old value first so `down` can restore it exactly, rather
        # than leaving the host as a router. Guarded so re-running `up` cannot overwrite the saved
        # original with the value we ourselves set.
        if [ ! -f "$IP_FORWARD_STATE_FILE" ]; then
            sysctl -n net.ipv4.ip_forward > "$IP_FORWARD_STATE_FILE"
        fi
        sysctl -q -w net.ipv4.ip_forward=1

        # Rewrite the guest's source address to the host's on the way out, so replies come back.
        # -C tests for the rule first so re-running does not stack duplicates.
        iptables -t nat -C POSTROUTING -s "$BRIDGE_SUBNET" -o "$uplink" -j MASQUERADE 2>/dev/null \
            || iptables -t nat -A POSTROUTING -s "$BRIDGE_SUBNET" -o "$uplink" -j MASQUERADE

        # Explicitly allow forwarding both ways. Needed because a default DROP policy on FORWARD is
        # common on machines with Docker installed, and it would silently break the guest's internet.
        iptables -C FORWARD -i "$BRIDGE_NAME" -o "$uplink" -j ACCEPT 2>/dev/null \
            || iptables -I FORWARD -i "$BRIDGE_NAME" -o "$uplink" -j ACCEPT
        iptables -C FORWARD -i "$uplink" -o "$BRIDGE_NAME" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
            || iptables -I FORWARD -i "$uplink" -o "$BRIDGE_NAME" -m state --state RELATED,ESTABLISHED -j ACCEPT

        echo "NAT enabled via $uplink"
    else
        echo "WARNING: no default route or iptables found, skipping NAT. LAN sharing still works, but the emulator will have no internet." >&2
    fi

    echo "LAN bridge up. Host is $BRIDGE_ADDRESS on $BRIDGE_NAME."
}

#
# Tears the LAN bridge down and puts the host's network config back as it was (privileged). Internal:
# invoked with sudo by `cmd_down`. Safe to re-run.
#
bridge_down() {
    require_root "__bridge-down"

    # Remove this caller's taps first. Removing a tap detaches it from the bridge as well. Only the
    # taps named in PSPHERE_TAPS go, so tearing down the pool never pulls the single emulator's tap
    # out from under it, or the other way round.
    local netcard
    for netcard in $PSPHERE_TAPS; do
        if ip link show "$netcard" >/dev/null 2>&1; then
            ip link del "$netcard"
            echo "Removed $netcard."
        fi
    done

    # The bridge, the DHCP server and the NAT rules are shared between the single emulator and the
    # pool, so they are only torn down once nothing is plugged into the bridge any more.
    if [ -n "$(ip -o link show master "$BRIDGE_NAME" 2>/dev/null)" ]; then
        echo "Other taps are still on $BRIDGE_NAME; leaving the bridge, DHCP and NAT up."
        return 0
    fi

    # Stop the DHCP server first, so it is not left holding an interface that is about to vanish.
    if [ -f "$DNSMASQ_PID_FILE" ]; then
        kill "$(cat "$DNSMASQ_PID_FILE")" 2>/dev/null || true
        rm -f "$DNSMASQ_PID_FILE"
        echo "DHCP server stopped."
    else
        # Fallback for a lost pid file, which would otherwise strand the process. Matched on our own
        # bridge name specifically so this can never kill an unrelated dnsmasq, such as the one
        # libvirt or NetworkManager runs.
        pkill -f "dnsmasq.*--interface=$BRIDGE_NAME" 2>/dev/null || true
    fi

    # Put IP forwarding back exactly as it was. Skipped silently when the state file is absent,
    # which means `up` never got as far as changing it.
    if [ -f "$IP_FORWARD_STATE_FILE" ]; then
        sysctl -q -w net.ipv4.ip_forward="$(cat "$IP_FORWARD_STATE_FILE")"
        echo "Restored net.ipv4.ip_forward to $(cat "$IP_FORWARD_STATE_FILE")."
        rm -f "$IP_FORWARD_STATE_FILE"
    fi

    # Drop the NAT and forwarding rules. Left behind they are harmless but they accumulate and
    # confuse anyone reading the firewall later.
    local uplink
    uplink="$(uplink_interface)"
    if [ -n "$uplink" ] && command -v iptables >/dev/null 2>&1; then
        iptables -t nat -D POSTROUTING -s "$BRIDGE_SUBNET" -o "$uplink" -j MASQUERADE 2>/dev/null || true
        iptables -D FORWARD -i "$BRIDGE_NAME" -o "$uplink" -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -i "$uplink" -o "$BRIDGE_NAME" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    fi

    if ip link show "$BRIDGE_NAME" >/dev/null 2>&1; then
        ip link del "$BRIDGE_NAME"
        echo "Removed $BRIDGE_NAME."
    fi

    echo "Segment is down. Your physical network was never touched."
}

#
# Prints the path to the emulator binary, which is usually not on PATH even with the SDK installed.
# Prints nothing when it cannot be found.
#
emulator_path() {
    if command -v emulator >/dev/null 2>&1; then
        command -v emulator
        return 0
    fi

    local candidate="${ANDROID_HOME:-${HOME}/Android/Sdk}/emulator/emulator"
    if [ -x "$candidate" ]; then
        echo "$candidate"
    fi

    return 0
}

#
# Prints the path of an installed system image directory, or nothing when the SDK has none. Prefers
# the highest API level, so a machine with several picks the newest.
#
installed_system_image() {
    local sdk
    sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
    ls -d "$sdk"/system-images/*/*/* 2>/dev/null | sort -V | tail -1
}

#
# Creates the base AVD from an installed system image, so a machine that has never had one can still
# bring up an emulator or a pool. Prints nothing and fails when the SDK has no system image, which is
# the one thing this cannot conjure: it is several GB of Android and has to be downloaded.
#
# Written by hand rather than with avdmanager, because avdmanager lives in cmdline-tools, which is a
# separate SDK package that is frequently not installed (it is not on this machine). The format is
# only config.ini plus an .ini pointing at it, which is the same thing clone_avd writes.
# Usage: create_base_avd <avd_name>
#
create_base_avd() {
    local name="$1"
    local sdk image api tag abi home dir
    sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"

    image="$(installed_system_image)"
    if [ -z "$image" ]; then
        echo "ERROR: no AVD exists and the SDK has no system image to build one from." >&2
        echo "Install one in Android Studio (Device Manager, or SDK Manager > SDK Platforms)," >&2
        echo "or with: sdkmanager 'system-images;android-34;google_apis;x86_64'" >&2
        return 1
    fi

    # The three path components after system-images/ are the API level, the tag and the ABI, which
    # are exactly what config.ini needs to identify the image.
    abi="$(basename "$image")"
    tag="$(basename "$(dirname "$image")")"
    api="$(basename "$(dirname "$(dirname "$image")")")"

    home="$(avd_home)"
    dir="$home/$name.avd"
    mkdir -p "$dir"

    # A minimal but complete hardware profile. Anything not named here the emulator defaults for
    # itself; these are the settings the tests actually depend on (a writable data partition big
    # enough for the fixtures, and a phone-sized screen).
    cat > "$dir/config.ini" <<CONFIG
AvdId=$name
avd.ini.displayname=$name
avd.ini.encoding=UTF-8
abi.type=$abi
image.sysdir.1=system-images/$api/$tag/$abi/
tag.id=$tag
hw.cpu.arch=x86_64
hw.ramSize=2048
hw.lcd.width=1080
hw.lcd.height=2400
hw.lcd.density=440
hw.gpu.enabled=yes
hw.gpu.mode=swiftshader_indirect
hw.keyboard=yes
disk.dataPartition.size=$AVD_DATA_PARTITION_SIZE
CONFIG

    {
        echo "avd.ini.encoding=UTF-8"
        echo "path=$dir"
        echo "path.rel=avd/$name.avd"
        echo "target=$api"
    } > "$home/$name.ini"

    echo "Created base AVD '$name' from $api/$tag/$abi." >&2
}

#
# Prints the AVD to use, creating one first when the machine has none. This is what lets `up` and
# `pool-up` work on a fresh machine that has never had an emulator.
#
ensure_base_avd() {
    local existing
    existing="$(base_avd_name)"
    if [ -n "$existing" ]; then
        echo "$existing"
        return 0
    fi

    if ! create_base_avd "$DEFAULT_BASE_AVD"; then
        return 1
    fi
    echo "$DEFAULT_BASE_AVD"
}

#
# Prints the name of the AVD that `up` and `pool-up` clone from: ANDROID_AVD when set, otherwise the
# first AVD that is not itself one of the clones they create. Prints nothing when the machine has no
# AVD at all.
#
base_avd_name() {
    local emulator
    emulator="$(emulator_path)"
    if [ -z "$emulator" ]; then
        return 0
    fi
    if [ -n "${ANDROID_AVD:-}" ]; then
        echo "$ANDROID_AVD"
        return 0
    fi
    "$emulator" -list-avds 2>/dev/null | grep -v '^$' | grep -v "^$POOL_AVD_PREFIX-" | grep -v "^${SINGLE_AVD_NAME}$" | head -1
}

#
# Brings an existing AVD's data partition size up to AVD_DATA_PARTITION_SIZE, rewriting the
# disk.dataPartition.size line in its config.ini when it differs and adding the line when it is
# absent. Prints what it changed. Touches no file at all when the value already matches, so calling
# it twice does nothing the second time.
#
# This exists because clone_avd returns early for a clone that is already there, so an AVD created
# before the size changed would otherwise keep the size it was cloned with forever.
#
# config.ini is the input to the next cold boot, which is why editing it between runs is what takes
# effect. A running emulator reads its own hardware-qemu.ini, which the emulator regenerates from
# config.ini at launch, so there is nothing to edit on a running one and nothing here disturbs it.
# The size itself only reaches the guest when userdata is created fresh, which is what pool-restart's
# -wipe-data does.
# Usage: ensure_avd_data_partition_size <avd_name>
#
ensure_avd_data_partition_size() {
    local name="$1"
    local home ini dir config current temp
    home="$(avd_home)"
    ini="$home/$name.ini"

    if [ ! -f "$ini" ]; then
        echo "ERROR: AVD '$name' not found at $ini." >&2
        return 1
    fi

    # The AVD's directory name does not have to match its name, so read it from the .ini, exactly as
    # clone_avd does.
    dir="$(grep '^path=' "$ini" | cut -d= -f2-)"
    config="$dir/config.ini"
    if [ ! -f "$config" ]; then
        echo "ERROR: AVD '$name' has no config.ini at $dir." >&2
        return 1
    fi

    # `|| true` because a config.ini with no such line makes grep exit 1, which under `set -e` would
    # abort the script rather than take the "add the line" branch below.
    current="$(grep '^disk\.dataPartition\.size=' "$config" | head -1 | cut -d= -f2- || true)"
    if [ "$current" = "$AVD_DATA_PARTITION_SIZE" ]; then
        return 0
    fi

    # Written to a temporary file beside the original and moved into place, so a config.ini is never
    # left half-written if this is interrupted.
    temp="$config.psphere-size"

    if [ -n "$current" ]; then
        sed "s/^disk\.dataPartition\.size=.*/disk.dataPartition.size=$AVD_DATA_PARTITION_SIZE/" "$config" > "$temp"
        mv "$temp" "$config"
        echo "AVD '$name': data partition size $current -> $AVD_DATA_PARTITION_SIZE (applies on the next wiped boot)."
        return 0
    fi

    {
        cat "$config"

        # A config.ini that does not end in a newline would otherwise have the new setting joined
        # onto its last line. $(...) strips trailing newlines, so this is empty exactly when the
        # file already ends in one.
        if [ -n "$(tail -c 1 "$config")" ]; then
            echo ""
        fi
        echo "disk.dataPartition.size=$AVD_DATA_PARTITION_SIZE"
    } > "$temp"
    mv "$temp" "$config"
    echo "AVD '$name': data partition size set to $AVD_DATA_PARTITION_SIZE (applies on the next wiped boot)."
}

#
# Creates the pool's clone of the base AVD, unless it already exists.
#
# The clone is only config.ini plus an .ini pointing at its directory, about 8KB. config.ini holds
# no absolute paths (image.sysdir.1 is relative to the SDK), so nothing needs rewriting except the
# AVD's own name, and every disk image is created fresh from the shared system image on first cold
# boot. The base AVD's own 8GB of accumulated userdata and snapshots is deliberately not copied.
# Usage: clone_avd <base_avd_name> <clone_avd_name>
#
clone_avd() {
    local base="$1"
    local clone="$2"
    local home base_ini base_dir clone_dir clone_ini
    home="$(avd_home)"
    base_ini="$home/$base.ini"
    clone_dir="$home/$clone.avd"
    clone_ini="$home/$clone.ini"

    if [ -f "$clone_ini" ] && [ -f "$clone_dir/config.ini" ]; then
        return 0
    fi

    if [ ! -f "$base_ini" ]; then
        echo "ERROR: base AVD '$base' not found at $base_ini." >&2
        return 1
    fi

    # The AVD's directory name does not have to match its name, so read it from the .ini rather
    # than assuming (the stock "Medium_Phone_API_36.1" lives in "Medium_Phone.avd", for instance).
    base_dir="$(grep '^path=' "$base_ini" | cut -d= -f2-)"
    if [ ! -f "$base_dir/config.ini" ]; then
        echo "ERROR: base AVD '$base' has no config.ini at $base_dir." >&2
        return 1
    fi

    mkdir -p "$clone_dir"
    sed -e "s/^AvdId=.*/AvdId=$clone/" \
        -e "s/^avd.ini.displayname=.*/avd.ini.displayname=$clone/" \
        "$base_dir/config.ini" > "$clone_dir/config.ini"
    {
        echo "avd.ini.encoding=UTF-8"
        echo "path=$clone_dir"
        echo "path.rel=avd/$clone.avd"
        grep '^target=' "$base_ini" || true
    } > "$clone_ini"

    echo "Cloned AVD '$base' to '$clone'."
}

#
# Prints "<serial> <avd-name>" for every attached emulator that adb reports as "device", meaning it
# has finished booting and is usable. This is the only place that asks adb what is attached and what
# each one is running, so the filters below cannot drift apart. A real phone has no AVD name and
# prints an empty second field, which matches neither filter.
#
attached_emulators() {
    local adb serial avd
    adb="$(adb_path)"
    if [ -z "$adb" ]; then
        return 0
    fi
    for serial in $("$adb" devices 2>/dev/null | awk 'NR > 1 && $2 == "device" { print $1 }'); do
        # Capped, because this is on the polling path of every wait: an adb call that wedges here
        # would hang the wait rather than fail it, and a wait that never returns looks like a
        # machine that has locked up.
        avd="$(timeout 8 "$adb" -s "$serial" emu avd name 2>/dev/null | head -1 | tr -d '\r')"
        echo "$serial $avd"
    done
}

#
# Prints the serials of every attached emulator/device, whatever it happens to be running.
#
attached_serials() {
    attached_emulators | awk '{ print $1 }'
}

#
# Prints the serials of attached emulators running one of the pool's clone AVDs. Used so the pool
# only ever stops emulators it started, never the single hand-testing one.
#
pool_serials() {
    attached_emulators | awk -v prefix="$POOL_AVD_PREFIX-" 'index($2, prefix) == 1 { print $1 }'
}

#
# Prints the serials of attached emulators running the single hand-testing AVD, which is recognised
# by its own name rather than by being "not a pool clone". That distinction is the whole point: a
# running pool is not the hand-testing emulator, and treating it as one made `up` do nothing.
#
single_serials() {
    attached_emulators | awk -v name="$SINGLE_AVD_NAME" '$2 == name { print $1 }'
}

#
# True when the LAN bridge is fully up for the given tap: the bridge and that tap exist and the DHCP
# server is running. Usage: bridge_is_up <tap_name>
#
bridge_is_up() {
    ip link show "$BRIDGE_NAME" >/dev/null 2>&1 \
        && ip link show "$1" >/dev/null 2>&1 \
        && dnsmasq_running
}

#
# Installs the pool's slice unit into the user's systemd unit directory, so the memory limits in it
# actually apply, and reloads the user manager so it is read.
#
# Only ever creates the file. An installed unit that differs from the one in the repo is left exactly
# as it is and reported instead, because it may have been tuned by hand for this machine and quietly
# replacing it would throw that away with nothing to say it happened.
#
ensure_pool_slice() {
    local installed="$POOL_SLICE_INSTALL_DIR/$POOL_SLICE"

    if ! command -v systemd-run >/dev/null 2>&1; then
        echo "ERROR: systemd-run not found, so the emulator's memory cannot be bounded." >&2
        echo "       This script starts each emulator as a transient systemd user service." >&2
        exit 1
    fi

    # The copy in this repository is the source of truth, so it is installed whenever the installed
    # copy is missing or has drifted from it.
    #
    # This used to install only when nothing was there, and print a note when the two differed. That
    # left the checked-in file unable to reach the machine after the first install: the limits in the
    # repository could be changed, reviewed and committed while every machine carried on running
    # whatever it happened to have, and the only thing standing between them was a note somebody had
    # to read and act on. In practice one machine ran for a day on 30G/36G while the repository said
    # 20G/26G. A source of truth that cannot reach the thing it governs is not one.
    #
    # A local edit is overwritten, which is the point: change the limits here, where they are
    # reviewed, rather than on one machine. The previous contents are printed first so an
    # intentional local change is visible rather than silently lost.
    if [ ! -f "$installed" ]; then
        mkdir -p "$POOL_SLICE_INSTALL_DIR"
        cp "$POOL_SLICE_SOURCE" "$installed"
        echo "Installed $POOL_SLICE into $POOL_SLICE_INSTALL_DIR."
        systemctl --user daemon-reload
        return 0
    fi

    if ! cmp -s "$POOL_SLICE_SOURCE" "$installed"; then
        echo "$installed differed from the copy in this repo. Replacing it with the repo's copy."
        echo "  limits it had:  $(grep -hE '^Memory(High|Max)=' "$installed" | tr '\n' ' ')"
        echo "  limits it gets: $(grep -hE '^Memory(High|Max)=' "$POOL_SLICE_SOURCE" | tr '\n' ' ')"
        cp "$POOL_SLICE_SOURCE" "$installed"
        systemctl --user daemon-reload
    fi
}

#
# Prints the command line the emulator is launched with, one argument per line, and runs nothing.
# The last argument says whether to wipe: non-empty appends -wipe-data, empty leaves it off.
#
# It is a function of its own so that what start_emulator_bg is about to run can be read and checked
# without starting an emulator, which matters because starting one is the human's job here and the
# agent must not do it.
#
# -no-snapshot forces a cold boot. A quick-boot snapshot restores the guest's previous network state
# (behind the 10.0.2.x virtual router), so wlan0 never re-associates to the freshly created tap and
# stays NO-CARRIER. A cold boot brings wifi up fresh and associates it to -wifi-tap, which is the
# whole point.
#
# -wipe-data recreates the data partition from the system image instead of reusing the overlay left
# by the last run. It is what makes a change to AVD_DATA_PARTITION_SIZE reach the guest, because the
# partition is sized when userdata-qemu.img is created and never afterwards. It also throws away
# everything the guest had, including the installed app.
#
# -gpu swiftshader_indirect pins software rendering. Two settings have been tried here and both are
# recorded, because the second was chosen on evidence produced by the first.
#
# "auto", the original, let the emulator pick a backend at runtime. It chose software rendering
# anyway (Vulkan 'lavapipe', GLES 'swangle'), and four of five pool emulators crashed inside ten
# minutes during a suite run, each log ending in crash-handler output with a minidump written.
#
# "off" was tried next. It removed GPU emulation entirely and produced a new, repeatable failure: the
# app started, its WebView took fifteen seconds to bring up a sandboxed rendering process, and the
# main thread then hung with an ANR. Two separate occurrences, both inside WebView start-up, one
# blocked on a mutex in WebView class initialisation. The devices were healthy throughout, so this was
# the app hanging rather than the emulator dying. "off" leaves Chromium with no GL path at all, which
# is what its start-up needs.
#
# "swiftshader_indirect" keeps rendering in software, so nothing depends on the host GPU and the
# backend no longer varies between emulators, while still giving the WebView something to render on.
# It is the usual choice for unattended runs.
#
# It is passed on the command line as well as set in the AVD config, because the command line
# overrides the config and an AVD cloned before that change would otherwise keep the old setting.
#
# None of this has been shown to stop the original crashes. There is no stack trace for those (no
# minidump symboliser is installed), and the dump has been kept for that. What is established is
# narrower: "off" causes WebView start-up hangs, and this setting exists to avoid them without going
# back to a backend chosen at runtime.
# Usage: emulator_launch_argv <emulator_binary> <avd_name> <tap_name> <wipe>
#
emulator_launch_argv() {
    local emulator="$1"
    local avd="$2"
    local netcard="$3"
    local wipe="$4"

    echo "$emulator"
    echo "-avd"
    echo "$avd"
    echo "-no-snapshot"
    echo "-no-boot-anim"
    echo "-gpu"
    echo "swiftshader_indirect"
    echo "-wifi-tap"
    echo "$netcard"

    if [ -n "$wipe" ]; then
        echo "-wipe-data"
    fi
}

#
# Starts one writable emulator in the background on the given tap, so it lands on the bridge. Must
# run as your user, not root: the emulator can only open a tap it owns. Nothing here is ever
# -read-only, so every emulator keeps its own state.
#
# The emulator runs as its own transient systemd user service inside the pool's slice, which is what
# bounds its memory. An emulator costs far more on the host than the AVD's hw.ramSize suggests: with
# hw.ramSize at 2GB, measured emulators have held between 4GB and 6.4GB each. A pool of them is
# enough to drive the whole session into systemd-oomd's kill path.
#
# A service also detaches by itself, so setsid is no longer needed, and captures the process's output
# itself, so the shell redirect is gone with it. Each emulator is a separate unit, so one that dies
# leaves the rest running.
#
# The last argument says whether to wipe the emulator's data partition on the way up. It is passed
# straight to emulator_launch_argv; see there for what it does and what it costs.
# Usage: start_emulator_bg <avd_name> <tap_name> <log_suffix> <wipe>
#
start_emulator_bg() {
    local avd="$1"
    local netcard="$2"
    local log_suffix="$3"
    local wipe="$4"

    if [ "$(id -u)" -eq 0 ]; then
        echo "ERROR: the emulator must run as your user, not root." >&2
        exit 1
    fi

    local emulator
    emulator="$(emulator_path)"
    if [ -z "$emulator" ]; then
        echo "ERROR: emulator not found (looked on PATH and in \${ANDROID_HOME:-\$HOME/Android/Sdk}/emulator)." >&2
        exit 1
    fi

    if ! ip link show "$netcard" >/dev/null 2>&1; then
        echo "ERROR: $netcard does not exist; the bridge is not up." >&2
        exit 1
    fi

    ensure_pool_slice

    # A transient unit starts from the user manager's environment rather than this shell's, so
    # anything the emulator needs that was exported from a shell profile has to be handed over
    # explicitly. The SDK variables are the ones that matter: an emulator that cannot see a
    # non-default ANDROID_AVD_HOME looks in the default AVD directory and finds nothing. The emulator
    # binary itself is passed as the absolute path emulator_path prints, so PATH does not come into
    # it.
    local setenv_args=()
    local variable_name
    for variable_name in ANDROID_HOME ANDROID_SDK_ROOT ANDROID_AVD_HOME; do
        if [ -n "${!variable_name:-}" ]; then
            setenv_args+=(--setenv="$variable_name=${!variable_name}")
        fi
    done

    # A pool emulator's unit name comes from pool_unit_name rather than being built here, so the
    # repair and diagnostic code, which has only an index to work from, cannot end up looking at a
    # different name from the one this started.
    local unit
    case "$log_suffix" in
        pool-*)
            unit="$(pool_unit_name "${log_suffix#pool-}")"
            ;;
        *)
            unit="psphere-emu-$log_suffix"
            ;;
    esac

    # A transient unit disappears once it has stopped, but one whose emulator exited non-zero stays
    # behind in the failed state, and starting this name again would collide with it. This clears
    # that leftover record and nothing else: it cannot stop an emulator that is running.
    systemctl --user reset-failed "$unit" 2>/dev/null || true

    if [ -n "$wipe" ]; then
        echo "Starting emulator '$avd' on $netcard as $unit (cold boot with -wipe-data, so its data partition is recreated)..."
    else
        echo "Starting emulator '$avd' on $netcard as $unit (cold boot, so wifi associates to the bridge)..."
    fi

    # The emulator's own arguments come from emulator_launch_argv, which is where they are explained,
    # and are read one per line because none of them can contain a newline.
    local -a emulator_argv
    mapfile -t emulator_argv < <(emulator_launch_argv "$emulator" "$avd" "$netcard" "$wipe")

    # MemoryHigh rather than MemoryMax per emulator: MemoryHigh throttles the emulator and reclaims
    # from it, where MemoryMax would have the kernel kill it outright, and an emulator sits close
    # enough to any ceiling worth setting that a hard kill would be a coin toss. The slice's own
    # MemoryMax is the hard backstop, and it covers the pool rather than one member of it.
    #
    # 8G is a per-emulator sanity check, not the real limit: it sits above what a working emulator
    # asks for, so one behaving normally never feels it and one running away is slowed down on its
    # own rather than at the expense of the other four. What bounds a test run is the slice, in
    # psphere-pool.slice.
    #
    # It is above real demand, which was measured at 6.0GB to 6.7GB an emulator under a suite run:
    # 4.19GB to 4.70GB of anonymous memory, which is not page cache and cannot be reclaimed, plus
    # 1.34GB to 1.99GB in swap. A limit under that figure does not slow a runaway, it throttles every
    # emulator all the time and pushes the shortfall to swap, which is the slow path that makes an
    # emulator miss timing.
    #
    # It is also what makes the slice's limit reachable: five emulators at 8G can use the 40G the
    # slice allows, where a lower number here caps the pool below it no matter what the slice says.
    #
    # ${setenv_args[@]+"${setenv_args[@]}"} rather than "${setenv_args[@]}" because this script runs
    # under `set -u`, where expanding an empty array is an unbound-variable error on older bash. The
    # + form expands to nothing at all when the array is empty, which is what is wanted.
    #
    # append: rather than file:. file: truncates the log when the unit opens it, so restarting an
    # emulator destroys the output of the one that just died, which is the only account of why it
    # died. During the recovery on 2026-08-09 the pool's logs held nothing but crash output from
    # earlier boots, and there was no way to tell whether the processes that had just been started
    # had written anything at all. The logs now grow rather than being reset each time; they live in
    # /tmp, so a reboot clears them, and pool-diagnose reads the tail rather than the whole file.
    systemd-run --user --unit="$unit" \
        --slice="$POOL_SLICE" \
        --description="Photosphere emulator: $avd on $netcard" \
        -p MemoryHigh=8G \
        -p MemorySwapMax=2G \
        -p StandardOutput="append:$(pool_log_path "$log_suffix")" \
        -p StandardError="append:$(pool_log_path "$log_suffix")" \
        ${setenv_args[@]+"${setenv_args[@]}"} \
        "${emulator_argv[@]}"
}

#
# Prints how many of the emulators listed by <serial_source> are on the LAN bridge. The source is
# the name of a function that prints serials, so the count can be narrowed to just the pool or just
# the hand-testing emulator; it defaults to every attached device. Read-only.
# Usage: ready_device_count [serial_source_function]
#
ready_device_count() {
    local serial_source="${1:-attached_serials}"
    local adb serial count
    adb="$(adb_path)"
    count=0
    if [ -z "$adb" ]; then
        echo 0
        return 0
    fi
    for serial in $("$serial_source"); do
        if timeout 8 "$adb" -s "$serial" shell ip addr show wlan0 2>/dev/null | tr -d '\r' | grep -q 'inet 192\.168\.55\.'; then
            count=$((count + 1))
        fi
    done
    echo "$count"
}

#
# Polls until at least <wanted> of the emulators listed by <serial_source> are ready (started AND on
# the bridge), or the timeout passes. The source is re-read on every poll, so an emulator that has
# not started yet is picked up as soon as it appears.
# Usage: wait_for_ready <timeout_seconds> <wanted_count> [serial_source_function]
#
wait_for_ready() {
    local timeout="${1:-180}"
    local wanted="${2:-1}"
    local serial_source="${3:-attached_serials}"
    local start="$SECONDS"
    local elapsed=0
    local last_note=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if [ "$(ready_device_count "$serial_source")" -ge "$wanted" ]; then
            return 0
        fi

        # Print a progress line every 15s so a long wait is not silent dead air.
        if [ "$((elapsed - last_note))" -ge 15 ]; then
            echo "  still waiting for the guest to reach the bridge (${elapsed}s / ${timeout}s)..."
            last_note="$elapsed"
        fi
        sleep 3

        # Track real wall-clock elapsed (SECONDS), not a fixed increment, so the
        # timeout is honest even though cmd_status itself takes a few seconds.
        elapsed="$((SECONDS - start))"
    done
    return 1
}

#
# Brings everything up: the LAN bridge (privileged, via sudo, automatically) and the emulator attached
# to it, then waits until it is ready. Run as your user; it sudo's only for the bridge.
#
cmd_up() {
    if [ "$(id -u)" -eq 0 ]; then
        echo "ERROR: run 'up' as your user (it uses sudo only for the bridge)." >&2
        exit 1
    fi

    local netcard
    netcard="$(netcard_name)"

    if bridge_is_up "$netcard"; then
        echo "LAN bridge already up."
    else
        echo "Bringing up the LAN bridge (needs sudo)..."
        # Pass GUEST_DNS and the tap list through: sudo strips the environment, and the bridge
        # setup reads both.
        sudo GUEST_DNS="$GUEST_DNS" PSPHERE_TAPS="$netcard" "$0" __bridge-up
    fi

    # Only the hand-testing emulator counts here, recognised by its own AVD name. A running pool is
    # deliberately not counted: it has its own AVDs and its own taps and is not this emulator. When
    # this asked "is any device attached?" instead, a running pool answered yes, so `up` took the
    # branch below, reported the pool as ready and started nothing.
    if [ -n "$(single_serials)" ]; then
        # It is already running. If it is on the bridge we are done. If it is off the bridge we
        # cannot attach it: -wifi-tap is bound at launch, so a running emulator that is off the
        # bridge can never join it. Do NOT kill it here (up is non-destructive); report it and tell
        # the user to restart. Give a short grace first to ride out a transient gap.
        echo "The '$SINGLE_AVD_NAME' emulator is attached; checking whether it is on the bridge..."
        if wait_for_ready 25 1 single_serials; then
            cmd_status
            return 0
        fi
        echo "" >&2
        echo "The '$SINGLE_AVD_NAME' emulator is not on the bridge and cannot be added to it: the" >&2
        echo "-wifi-tap attachment is fixed at launch, so a running emulator that is off the bridge" >&2
        echo "can never join it. This is unrecoverable without a restart." >&2
        echo "Run: bun run emu:and:restart   (or: bun run emu:and:down then bun run emu:and:up)" >&2
        cmd_status >&2 || true
        exit 1
    fi

    # Run on a clone of the base AVD rather than on the base AVD itself, exactly as the pool does,
    # because that is what gives this emulator a name of its own to be identified by. The clone is
    # about 8KB and is writable, so state kept in it survives between runs.
    local base
    base="$(ensure_base_avd)" || exit 1
    clone_avd "$base" "$SINGLE_AVD_NAME" || exit 1

    # Keeps the hand-testing emulator on the same partition size as the pool, so the two do not drift
    # apart and a problem seen on one is reproducible on the other.
    ensure_avd_data_partition_size "$SINGLE_AVD_NAME" || exit 1

    start_emulator_bg "$SINGLE_AVD_NAME" "$netcard" "single" ""

    echo "Waiting for the emulator to be ready on the bridge (up to 180s)..."
    if wait_for_ready 180 1 single_serials; then
        cmd_status
    else
        echo "Timed out waiting for the emulator to reach the bridge." >&2
        cmd_status || true
        echo "If an emulator is up but off the bridge, run: bun run emu:and:restart" >&2
        exit 1
    fi
}

#
# Brings up the pool: one writable clone AVD per instance, each on its own tap, all on the same
# bridge as the single emulator. Deliberately independent of `up`, so a pool can be started and
# stopped while a hand-testing emulator keeps running untouched.
#
# Takes an optional --wipe, which starts every emulator with -wipe-data and so resets its data
# partition to baseline. Only pool-restart passes it. A plain pool-up deliberately does not, because
# pool-up is what brings the pool back after emulators have crashed, and throwing the installed app
# away on a recovery would turn it into a full reinstall.
# Usage: cmd_pool_up [--wipe]
#
cmd_pool_up() {
    if [ "$(id -u)" -eq 0 ]; then
        echo "ERROR: run 'pool-up' as your user (it uses sudo only for the bridge)." >&2
        exit 1
    fi

    local wipe=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --wipe)
                wipe="wipe"
                ;;
            *)
                echo "ERROR: unknown argument to pool-up: $1 (only --wipe is understood)." >&2
                exit 1
                ;;
        esac
        shift
    done

    local base
    base="$(ensure_base_avd)" || exit 1
    echo "Cloning the pool's AVDs from '$base'..."

    local index taps=""
    for index in $(seq 0 $((PHOTOSPHERE_EMULATOR_COUNT - 1))); do
        clone_avd "$base" "$(pool_avd_name "$index")" || exit 1

        # After the clone rather than inside it, because clone_avd returns early for a clone that
        # already exists and would never reach one created before the size changed.
        ensure_avd_data_partition_size "$(pool_avd_name "$index")" || exit 1

        taps="$taps $(pool_netcard_name "$index")"
    done

    # Every pool tap has to exist, so the check is on the last one rather than any one of them.
    if bridge_is_up "$(pool_netcard_name $((PHOTOSPHERE_EMULATOR_COUNT - 1)))"; then
        echo "LAN bridge already up for the pool."
    else
        echo "Bringing up the LAN bridge for $PHOTOSPHERE_EMULATOR_COUNT pool taps (needs sudo)..."
        sudo GUEST_DNS="$GUEST_DNS" PSPHERE_TAPS="$taps" "$0" __bridge-up
    fi

    # Count what is already ready, so the pool's own target is on top of any single emulator that
    # is already up and must not be disturbed.
    local already
    already="$(ready_device_count)"

    local running
    running="$(pool_serials | wc -l)"
    if [ "$running" -gt 0 ]; then
        echo "$running pool emulator(s) already running; starting the rest."
    fi

    for index in $(seq 0 $((PHOTOSPHERE_EMULATOR_COUNT - 1))); do
        start_emulator_bg "$(pool_avd_name "$index")" "$(pool_netcard_name "$index")" "pool-$index" "$wipe"
    done

    echo "Waiting for $PHOTOSPHERE_EMULATOR_COUNT pool emulator(s) to reach the bridge (up to 600s)..."
    if wait_for_ready 600 $((already + PHOTOSPHERE_EMULATOR_COUNT - running)); then
        cmd_status
    else
        echo "Timed out waiting for the pool to reach the bridge." >&2
        cmd_status || true
        exit 1
    fi
}

#
# Waits until systemd has released the pool's transient unit names, so the same names can be started
# again. Read-only: it stops nothing, it only watches.
#
# adb drops an emulator from its device list as soon as the emulator's socket goes, but systemd keeps
# the unit loaded for a moment longer while it reaps the process. Waiting only on adb, as this used
# to, let `pool-up` run while a unit was still deactivating, and `systemd-run` refuses a name that is
# still loaded: "Unit psphere-emu-pool-0.service was already loaded or has a fragment file". That
# aborted the run on the first emulator, so `pool-restart` could not bring the pool back at all,
# which is the one thing it exists to do. Waiting is what handles that case: `systemctl reset-failed`
# does not, because such a unit is not failed, it is still on its way out.
#
# A unit whose emulator died IS failed, though, and that is the other way the names stay taken. An
# emulator that segfaults leaves its transient unit loaded in the failed state, and systemd keeps a
# failed unit loaded indefinitely so its status can still be read: no amount of waiting releases it.
# That is cleared here rather than waited on, because otherwise the first crash of any pool emulator
# blocks every later `pool-restart` until somebody runs reset-failed by hand, and emulators do crash.
# Only the pool's own units are touched, and only ones already dead, so nothing running is disturbed.
#
wait_for_pool_units_released() {
    local waited=0

    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi

    while [ "$waited" -lt "$POOL_UNIT_RELEASE_TIMEOUT_SECONDS" ]; do
        # Inside the loop, not once before it: a unit that is on its way out when this starts can
        # reach the failed state part way through the wait, and would then never be cleared at all.
        systemctl --user reset-failed "$POOL_UNIT_GLOB" >/dev/null 2>&1 || true

        if [ "$(systemctl --user list-units --all --no-legend --plain "$POOL_UNIT_GLOB" 2>/dev/null | wc -l)" -eq 0 ]; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    echo "ERROR: systemd still has the pool's units loaded after ${POOL_UNIT_RELEASE_TIMEOUT_SECONDS}s," >&2
    echo "so starting the pool again would collide with them. Still loaded:" >&2
    systemctl --user list-units --all --no-legend --plain "$POOL_UNIT_GLOB" >&2 2>/dev/null || true
    return 1
}

#
# Stops the pool and removes only its taps. Never touches the single hand-testing emulator: the
# emulators stopped are exactly those whose AVD is one of the pool's clones, and the taps removed
# are exactly the pool's. The clone AVDs are left on disk (about 8KB each) so a later pool start
# does not have to rebuild them.
#
cmd_pool_down() {
    local adb serial stopped=0
    adb="$(adb_path)"
    for serial in $(pool_serials); do
        echo "Stopping pool emulator $serial..."
        "$adb" -s "$serial" emu kill >/dev/null 2>&1 || true
        stopped=$((stopped + 1))
    done

    if [ "$stopped" -eq 0 ]; then
        echo "No pool emulators are running."
    else
        local waited=0
        while [ "$waited" -lt 30 ] && [ "$(pool_serials | wc -l)" -gt 0 ]; do
            sleep 1
            waited=$((waited + 1))
        done
        echo "Stopped $stopped pool emulator(s)."
    fi

    # Before the taps go, so a failure here leaves the pool as it was rather than half torn down.
    wait_for_pool_units_released || exit 1

    local index taps=""
    for index in $(seq 0 $((PHOTOSPHERE_EMULATOR_COUNT - 1))); do
        taps="$taps $(pool_netcard_name "$index")"
    done

    echo "Removing the pool's taps (needs sudo)..."
    sudo PSPHERE_TAPS="$taps" "$0" __bridge-down
}

#
# Stops the hand-testing emulator (if it is running) and waits for adb to drop it. Leaves the bridge
# alone; both cmd_down (full teardown) and cmd_restart use this.
#
# It is picked out by its AVD name, so a running pool is left alone (use `pool-down` for that), and
# so is any emulator you started yourself outside this script, which is not ours to kill.
#
stop_emulator() {
    local adb serial waited
    adb="$(adb_path)"
    if [ -z "$adb" ]; then
        return 0
    fi

    for serial in $(single_serials); do
        echo "Stopping $serial..."
        "$adb" -s "$serial" emu kill >/dev/null 2>&1 || true
    done

    waited=0
    while [ "$waited" -lt 30 ] && [ -n "$(single_serials)" ]; do
        sleep 1
        waited=$((waited + 1))
    done
}

#
# Brings everything down: stops the hand-testing emulator, then tears down the LAN bridge
# (privileged, via sudo), leaving a running pool and its taps alone.
#
cmd_down() {
    stop_emulator

    export PSPHERE_TAPS="$(netcard_name)"
    if ip link show "$BRIDGE_NAME" >/dev/null 2>&1 || dnsmasq_running; then
        echo "Bringing down the LAN bridge (needs sudo)..."
        sudo PSPHERE_TAPS="$PSPHERE_TAPS" "$0" __bridge-down
    else
        echo "LAN bridge already down."
    fi
}

#
# Stops everything and brings it back up on the bridge.
#
cmd_restart() {
    cmd_down
    cmd_up
}

#
# Stops the pool and brings it straight back up. Only the pool: the hand-testing emulator is left
# running, exactly as pool-down leaves it, and so is the bridge, which pool-up finds already in
# place. This is the way to pick up a change to the emulators' memory limits, since the limits are
# read when an emulator starts and cannot be applied to one already running.
#
# It also resets each pool emulator's data partition to baseline, by starting it with -wipe-data.
# That is how a change to AVD_DATA_PARTITION_SIZE takes effect: the partition is sized when
# userdata-qemu.img is created, so an emulator that already has one keeps its old size no matter what
# config.ini says. It is also the answer to a partition that has filled up, which is what happened to
# all five pool AVDs at 6G.
#
# What the wipe costs: it removes /data/local/tmp/psphere-apk.sha, the stamp android_ensure_apk in
# apps/smoke-tests/lib/android.sh compares against, so the first `test:and` after a restart reinstalls
# the APK on every emulator. That is once per restart rather than once per run, so the saving commit
# a01f52f2 made by not reinstalling an unchanged APK at the top of every run is untouched from the
# second run onwards.
#
cmd_pool_restart() {
    cmd_pool_down
    cmd_pool_up --wipe
}

#
# Prints "<active_state> <result> <main_pid>" for one pool index's unit, and "inactive none 0" when
# no such unit exists. Read-only: it looks at the unit and changes nothing about it.
#
# Never prints an empty field, so a caller can read the three with one `read` and compare them
# without first working out whether the unit was there at all. A transient unit disappears completely
# once it has stopped, so "no such unit" is the ordinary state of a pool index whose emulator is not
# running, not an error.
#
# The properties are read by name rather than positionally. `systemctl show --value` prints them in
# systemd's own order and not in the order they were asked for, which was confirmed here: asking for
# ActiveState, Result and MainPID prints the pid first.
# Usage: pool_unit_state <index>
#
pool_unit_state() {
    local unit properties load active result main_pid
    unit="$(pool_unit_name "$1")"

    if ! command -v systemctl >/dev/null 2>&1; then
        echo "inactive none 0"
        return 0
    fi

    properties="$(systemctl --user show -p LoadState -p ActiveState -p Result -p MainPID "$unit" 2>/dev/null || true)"
    load="$(printf '%s\n' "$properties" | awk -F= '$1 == "LoadState" { print $2 }')"
    if [ -z "$load" ] || [ "$load" = "not-found" ]; then
        echo "inactive none 0"
        return 0
    fi

    active="$(printf '%s\n' "$properties" | awk -F= '$1 == "ActiveState" { print $2 }')"
    result="$(printf '%s\n' "$properties" | awk -F= '$1 == "Result" { print $2 }')"
    main_pid="$(printf '%s\n' "$properties" | awk -F= '$1 == "MainPID" { print $2 }')"
    echo "${active:-inactive} ${result:-none} ${main_pid:-0}"
}

#
# Prints how many seconds ago one pool index's unit became active, or nothing when it is not active.
# Read-only.
#
# Read from the unit rather than from the guest, because an emulator that is not answering adb cannot
# be asked how long it has been up, and that is exactly the emulator whose age matters. Systemd's
# monotonic timestamp is microseconds since boot and /proc/uptime is seconds since boot; a machine
# that suspended counts that time in one and not the other, which is a few seconds' drift on an hours
# long figure and does not change any decision made from it.
# Usage: pool_unit_uptime_seconds <index>
#
pool_unit_uptime_seconds() {
    local unit monotonic uptime active
    unit="$(pool_unit_name "$1")"

    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi

    # A unit that has failed keeps the timestamp of when it last went active, so the state is checked
    # rather than inferred from the timestamp being there. An emulator that died an hour ago is not
    # an emulator that has been up all day.
    active="$(systemctl --user show -p ActiveState --value "$unit" 2>/dev/null || true)"
    if [ "$active" != "active" ]; then
        return 0
    fi

    monotonic="$(systemctl --user show -p ActiveEnterTimestampMonotonic --value "$unit" 2>/dev/null || true)"
    case "$monotonic" in
        ''|*[!0-9]*|0)
            return 0
            ;;
    esac

    uptime="$(awk '{ print int($1) }' /proc/uptime 2>/dev/null || true)"
    case "$uptime" in
        ''|*[!0-9]*)
            return 0
            ;;
    esac

    echo "$(( uptime - monotonic / 1000000 ))"
}

#
# Prints the process ids recorded in the given AVD's own lock files, one per line, and nothing when
# the AVD holds no lock. Read-only.
#
# What is actually there, read from a running pool AVD on this machine rather than assumed:
#
#   hardware-qemu.ini.lock   8 bytes, mode 0600. The pid of the emulator's qemu process in ASCII
#                            digits followed by a NUL. Confirmed against /proc: the pid in
#                            psphere-pool-0.avd named the qemu-system-x86_64 process running
#                            "-avd psphere-pool-0 ... -wifi-tap emu-pool-0".
#   multiinstance.lock       0 bytes. An flock target, so it carries no pid and there is nothing here
#                            to read from it.
#
# This exists because cmd_pool_down stops emulators only through `adb emu kill`, so an emulator that
# has crashed far enough for adb to drop it is never stopped at all. It keeps its AVD lock, and the
# next start of that AVD refuses. That is the state the pool was left in on 2026-08-09.
# Usage: pool_avd_lock_pids <avd_name>
#
pool_avd_lock_pids() {
    local avd="$1"
    local lock_file pid
    lock_file="$(avd_home)/$avd.avd/hardware-qemu.ini.lock"

    if [ ! -f "$lock_file" ]; then
        return 0
    fi

    # Everything that is not a digit is dropped, which covers the trailing NUL and any newline.
    pid="$(tr -dc '0-9' < "$lock_file" 2>/dev/null || true)"
    if [ -n "$pid" ]; then
        echo "$pid"
    fi
}

#
# True when the given pid is alive and is the emulator running the given AVD. Read-only.
#
# The pid comes from that AVD's own lock file, so this is a check on something that was recorded
# rather than a search for a process by name: the AVD name is compared against one whole argument in
# the process's command line, so psphere-pool-1 can never match psphere-pool-10.
# Usage: pid_is_emulator_for_avd <pid> <avd_name>
#
pid_is_emulator_for_avd() {
    local pid="$1"
    local avd="$2"

    if [ ! -d "/proc/$pid" ]; then
        return 1
    fi

    tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | grep -Fxq "$avd"
}

#
# Waits until systemd has released ONE pool index's transient unit name, so that name can be started
# again. Read-only: it stops nothing.
#
# Scoped to one unit, unlike wait_for_pool_units_released, which waits for the whole pool's glob and
# is right for pool-down, where every emulator is going. A repair restarts one emulator while the
# others keep running, so waiting on the glob would wait for units that are meant to still be there
# and time out every time.
#
# The reasoning is otherwise that function's: adb drops an emulator as soon as its socket goes but
# systemd keeps the unit loaded a moment longer while it reaps the process, and systemd-run refuses a
# name that is still loaded. A unit whose emulator died is failed instead, and stays loaded
# indefinitely, so that is cleared rather than waited on.
# Usage: wait_for_pool_unit_released <index>
#
wait_for_pool_unit_released() {
    local unit waited=0
    unit="$(pool_unit_name "$1")"

    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi

    while [ "$waited" -lt "$POOL_UNIT_RELEASE_TIMEOUT_SECONDS" ]; do
        # Inside the loop, not once before it: a unit on its way out when this starts can reach the
        # failed state part way through the wait, and would then never be cleared at all.
        systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true

        if [ "$(systemctl --user list-units --all --no-legend --plain "$unit.service" 2>/dev/null | wc -l)" -eq 0 ]; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    echo "ERROR: systemd still has $unit loaded after ${POOL_UNIT_RELEASE_TIMEOUT_SECONDS}s," >&2
    echo "so starting it again would collide with it." >&2
    systemctl --user list-units --all --no-legend --plain "$unit.service" >&2 2>/dev/null || true
    return 1
}

#
# Stops one pool emulator and says what it took, escalating rather than waiting indefinitely. Returns
# non-zero when the emulator is still alive at the end, so a caller never mistakes a stubborn one for
# a stopped one.
#
# Three stages, each bounded: `systemctl stop`, then SIGKILL through the unit, then, for a process
# that outlived its unit entirely, kill_process_tree on the pid recorded in the AVD's lock file. The
# last one is what `pool-down` cannot do: it kills through `adb emu kill`, which needs an emulator adb
# can still see, and a crashed emulator is exactly the one adb has dropped.
#
# Nothing here selects a process by matching a command line. The only pid it ever signals came out of
# that AVD's own lock file, and it is checked against /proc before it is touched.
# Usage: stop_pool_emulator <index>
#
stop_pool_emulator() {
    local index="$1"
    local unit avd load pid waited
    unit="$(pool_unit_name "$index")"
    avd="$(pool_avd_name "$index")"

    if command -v systemctl >/dev/null 2>&1; then
        echo "  stopping $unit (up to ${POOL_STOP_TIMEOUT_SECONDS}s)..."
        if ! timeout "$POOL_STOP_TIMEOUT_SECONDS" systemctl --user stop "$unit" >/dev/null 2>&1; then
            echo "  $unit did not stop within ${POOL_STOP_TIMEOUT_SECONDS}s."
        fi

        load="$(systemctl --user show -p LoadState --value "$unit" 2>/dev/null || true)"
        if [ -n "$load" ] && [ "$load" != "not-found" ]; then
            echo "  $unit is still loaded; sending SIGKILL through the unit."
            systemctl --user kill --signal=SIGKILL "$unit" >/dev/null 2>&1 || true

            waited=0
            while [ "$waited" -lt "$POOL_KILL_TIMEOUT_SECONDS" ]; do
                load="$(systemctl --user show -p LoadState --value "$unit" 2>/dev/null || true)"
                if [ -z "$load" ] || [ "$load" = "not-found" ]; then
                    break
                fi
                sleep 1
                waited=$((waited + 1))
            done
        fi

        systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
    fi

    # Whatever systemd thinks, the AVD's lock is what blocks the next start, so the pid in it is
    # checked directly.
    for pid in $(pool_avd_lock_pids "$avd"); do
        if pid_is_emulator_for_avd "$pid" "$avd"; then
            echo "  pid $pid is still running '$avd' after the unit went; killing it and its children."
            kill_process_tree "$pid"
        fi
    done

    for pid in $(pool_avd_lock_pids "$avd"); do
        if pid_is_emulator_for_avd "$pid" "$avd"; then
            echo "  ERROR: pid $pid is still running '$avd'. Index $index was not stopped." >&2
            return 1
        fi
    done

    echo "  index $index is stopped."
}

#
# Refuses, with the reason, when the pool's network is not there, and says who can put it back.
# Returns non-zero when anything is missing, and never runs sudo.
#
# This is what makes pool-repair a command with no privileges at all. The bridge, the taps and the
# DHCP server are the only parts of the pool that need root, they survive an emulator restart, and
# nothing in a restart requires them to be recreated. A repair therefore either finds them in place
# and needs nothing, or finds them gone and stops here.
#
require_pool_network() {
    local missing=() index netcard

    if ! ip link show "$BRIDGE_NAME" >/dev/null 2>&1; then
        missing+=("the bridge $BRIDGE_NAME does not exist")
    fi

    for index in $(seq 0 $((PHOTOSPHERE_EMULATOR_COUNT - 1))); do
        netcard="$(pool_netcard_name "$index")"
        if ! ip link show "$netcard" >/dev/null 2>&1; then
            missing+=("the tap $netcard does not exist")
        fi
    done

    if ! dnsmasq_running; then
        missing+=("the DHCP server (dnsmasq) is not running")
    fi

    if [ "${#missing[@]}" -eq 0 ]; then
        return 0
    fi

    echo "ERROR: the pool's network is not in place, so there is nothing here that can be repaired:" >&2
    local reason
    for reason in "${missing[@]}"; do
        echo "  - $reason" >&2
    done
    echo "" >&2
    echo "Only 'bun run emu:and:pool:up' creates those, and it needs sudo to do it. This command" >&2
    echo "never runs sudo and never creates or removes a tap, which is the whole point of it: it" >&2
    echo "restarts emulators and nothing else." >&2
    echo "" >&2
    echo "If you are an agent, stop here and ask the human to run 'bun run emu:and:pool:up'." >&2
    return 1
}

#
# Prints the adb serial of the attached emulator running the given pool index's AVD, or nothing when
# no such emulator is attached. Read-only.
# Usage: pool_serial_for_index <index>
#
pool_serial_for_index() {
    local avd
    avd="$(pool_avd_name "$1")"
    attached_emulators | awk -v want="$avd" '$2 == want { print $1; exit }'
}

# The pool index pool_repair_wait_serials answers for. wait_for_ready takes the NAME of a function
# that prints serials and re-reads it on every poll, so the index it should be watching has to reach
# that function some other way than an argument.
POOL_REPAIR_WAIT_INDEX=""

#
# Prints the serial of the emulator for POOL_REPAIR_WAIT_INDEX, for wait_for_ready to count. Read-only.
#
pool_repair_wait_serials() {
    if [ -z "$POOL_REPAIR_WAIT_INDEX" ]; then
        return 0
    fi
    pool_serial_for_index "$POOL_REPAIR_WAIT_INDEX"
}

#
# Prints one tab-separated line describing one pool index, and changes nothing. The fields, in order:
#
#   index    the pool index this line is about
#   serial   its adb serial, or "-" when adb does not list it
#   unit     its unit's ActiveState: active, inactive, failed, activating, deactivating
#   uptime   seconds since its unit went active, or "-" when it is not active
#   verdict  one word: the emulator_health_verdict of its emulator, or "stopped" when the unit is not
#            running, or "no-device" when the unit is running but adb has no serial for it
#   repair   yes when it should be restarted, no when it should be left alone
#   reason   why, in words, or "-" when there is nothing to say
#
# Everything that judges a pool index reads it from here: pool-repair, pool-check, and through
# pool-check the monitor. Every adb reading is taken once, which matters because a sick emulator
# answers nothing and costs the full timeout on every call to it.
#
# An emulator inside its grace period is never reported as needing repair however bad it looks,
# because a cold boot looks exactly like a failure from the outside: no adb device for the first half
# minute, then a device with no address for a while after that. Restarting one of those turns a boot
# that was going to finish into a boot that never does.
# Usage: pool_index_report <index>
#
pool_index_report() {
    local index="$1"
    local active result main_pid serial verdict uptime young="no" repair="no" reason="-"

    read -r active result main_pid <<< "$(pool_unit_state "$index")"
    uptime="$(pool_unit_uptime_seconds "$index")"
    serial="$(pool_serial_for_index "$index")"

    if [ -n "$uptime" ] && [ "$uptime" -lt "$POOL_REPAIR_GRACE_SECONDS" ]; then
        young="yes"
    fi

    if [ "$active" != "active" ]; then
        verdict="stopped"
        repair="yes"
        reason="its unit is $active (result: $result)"
    elif [ -z "$serial" ]; then
        verdict="no-device"
        if [ "$young" = "yes" ]; then
            reason="its unit is $uptime second(s) old, inside the ${POOL_REPAIR_GRACE_SECONDS}s a boot is allowed"
        else
            repair="yes"
            reason="its unit is active (pid $main_pid) but adb does not list its emulator"
        fi
    else
        verdict="$(emulator_health_verdict "$serial")"
        if [ "$verdict" = "healthy" ]; then
            reason="-"
        elif [ "$young" = "yes" ]; then
            reason="$serial is $verdict, and its unit is only $uptime second(s) old"
        else
            repair="yes"
            case "$verdict" in
                low-space)
                    reason="$serial has under ${EMULATOR_STATUS_LOW_SPACE_MB}MB free on $EMULATOR_STATUS_DEVICE_DATA_PATH"
                    ;;
                *)
                    reason="$serial is $verdict"
                    ;;
            esac
        fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$index" "${serial:--}" "$active" "${uptime:--}" "$verdict" "$repair" "$reason"
}

#
# Prints why one pool index needs repairing, and nothing at all when it does not. Read-only.
# Usage: pool_index_repair_reason <index>
#
pool_index_repair_reason() {
    local index serial unit uptime verdict repair reason
    IFS=$'\t' read -r index serial unit uptime verdict repair reason <<< "$(pool_index_report "$1")"
    if [ "$repair" = "yes" ]; then
        echo "$reason"
    fi
}

#
# Prints one pool_index_report line for every pool index and changes nothing. This is what a program
# reads: the monitor takes its whole decision from it, so the monitor and pool-repair can never
# disagree about which emulator is broken.
#
cmd_pool_check() {
    local index
    for index in $(seq 0 $((PHOTOSPHERE_EMULATOR_COUNT - 1))); do
        pool_index_report "$index"
    done
}

#
# Stops one pool index and starts it again, waiting for it to reach the LAN bridge. Returns 0 when it
# is back on the bridge, POOL_REPAIR_SKIPPED_STATUS when a test run holds its lock and it was left
# alone, and 1 when the repair failed.
#
# The harness lock is held for the whole repair rather than probed and released, because a probe
# leaves a window in which a test claims the device between the answer and the restart. See
# android_device_lock_path in emulator-config.sh for the lock itself.
# Usage: repair_pool_index <index>
#
repair_pool_index() {
    local index="$1"
    local serial fd status

    serial="$(pool_serial_for_index "$index")"
    if [ -z "$serial" ]; then
        # Nothing is attached for this index, so no test can be running on it and there is no lock to
        # take: a lock is on a serial, and adb has no serial to give.
        repair_pool_index_locked "$index"
        return $?
    fi

    if ! command -v flock >/dev/null 2>&1; then
        echo "  flock is not installed, so whether a test is using $serial cannot be established. Leaving index $index alone."
        return "$POOL_REPAIR_SKIPPED_STATUS"
    fi

    exec {fd}<>"$(android_device_lock_path "$serial")"
    if ! flock -n "$fd"; then
        exec {fd}>&-
        echo "  $serial is locked by a test run, which is using it right now. Leaving index $index alone."
        return "$POOL_REPAIR_SKIPPED_STATUS"
    fi

    status=0
    repair_pool_index_locked "$index" || status=$?
    exec {fd}>&-
    return "$status"
}

#
# The repair itself, with the emulator's harness lock already held (or established not to exist).
# Usage: repair_pool_index_locked <index>
#
repair_pool_index_locked() {
    local index="$1"
    local avd netcard

    avd="$(pool_avd_name "$index")"
    netcard="$(pool_netcard_name "$index")"

    if ! stop_pool_emulator "$index"; then
        return 1
    fi

    if ! wait_for_pool_unit_released "$index"; then
        return 1
    fi

    if ! ensure_avd_data_partition_size "$avd"; then
        return 1
    fi

    start_emulator_bg "$avd" "$netcard" "pool-$index" "wipe"

    echo "  waiting up to ${POOL_REPAIR_BOOT_TIMEOUT_SECONDS}s for index $index to reach the bridge..."
    POOL_REPAIR_WAIT_INDEX="$index"
    if wait_for_ready "$POOL_REPAIR_BOOT_TIMEOUT_SECONDS" 1 pool_repair_wait_serials; then
        POOL_REPAIR_WAIT_INDEX=""
        echo "  index $index is back on the bridge."
        return 0
    fi

    POOL_REPAIR_WAIT_INDEX=""
    echo "  index $index did not reach the bridge within ${POOL_REPAIR_BOOT_TIMEOUT_SECONDS}s." >&2
    return 1
}

#
# Restarts broken pool emulators, one at a time, without needing any privileges.
#
# It never touches the bridge, a tap or the DHCP server, and so never runs sudo and never blocks on a
# password prompt. That is what makes it the repair an unattended run, or an agent with no terminal,
# can actually perform: `pool-restart` cannot, because it begins by removing the pool's taps.
#
# With no arguments it works out which indexes are broken and repairs those. --index N repairs one,
# whatever state it is in. --all repairs every index.
#
# Repairs run in order and never in parallel. Five cold boots with -wipe-data at once is a large load
# on the machine, and the pool died under load in the first place; a repair that recreates the
# original conditions is not a repair. It also means a partly working pool never goes fully dark.
# Usage: cmd_pool_repair [--index N] [--all]
#
cmd_pool_repair() {
    if [ "$(id -u)" -eq 0 ]; then
        echo "ERROR: run 'pool-repair' as your user. It needs no privileges at all, and an emulator" >&2
        echo "started as root could not open its tap anyway." >&2
        exit 1
    fi

    local wanted_index="" repair_all="no"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --index)
                shift
                if [ "$#" -eq 0 ]; then
                    echo "ERROR: --index needs the index of a pool emulator." >&2
                    exit 1
                fi
                wanted_index="$1"
                ;;
            --all)
                repair_all="yes"
                ;;
            *)
                echo "ERROR: unknown argument to pool-repair: $1 (only --index N and --all are understood)." >&2
                exit 1
                ;;
        esac
        shift
    done

    if [ -n "$wanted_index" ]; then
        case "$wanted_index" in
            ''|*[!0-9]*)
                echo "ERROR: --index takes a number, not '$wanted_index'." >&2
                exit 1
                ;;
        esac
        if [ "$wanted_index" -ge "$PHOTOSPHERE_EMULATOR_COUNT" ]; then
            echo "ERROR: index $wanted_index is outside the pool, which is $PHOTOSPHERE_EMULATOR_COUNT emulator(s), so 0 to $((PHOTOSPHERE_EMULATOR_COUNT - 1))." >&2
            exit 1
        fi
    fi

    if ! require_pool_network; then
        exit 1
    fi

    # Which indexes to repair, decided before any of them is touched, so the list cannot grow as a
    # restart momentarily takes an emulator off the bridge.
    local index reason
    local -a indexes=()
    local -a reasons=()

    if [ -n "$wanted_index" ]; then
        indexes+=("$wanted_index")
        reasons+=("--index $wanted_index was given")
    elif [ "$repair_all" = "yes" ]; then
        for index in $(seq 0 $((PHOTOSPHERE_EMULATOR_COUNT - 1))); do
            indexes+=("$index")
            reasons+=("--all was given")
        done
    else
        echo "Looking for broken pool emulators..."
        for index in $(seq 0 $((PHOTOSPHERE_EMULATOR_COUNT - 1))); do
            reason="$(pool_index_repair_reason "$index")"
            if [ -n "$reason" ]; then
                indexes+=("$index")
                reasons+=("$reason")
            else
                echo "  index $index is fine."
            fi
        done
    fi

    if [ "${#indexes[@]}" -eq 0 ]; then
        echo "Nothing to repair: every pool emulator is healthy."
        return 0
    fi

    local position=0 failed=0 skipped=0 repaired=0 status
    for index in "${indexes[@]}"; do
        echo ""
        echo "Repairing index $index: ${reasons[$position]}"
        position=$((position + 1))

        status=0
        repair_pool_index "$index" || status=$?
        case "$status" in
            0)
                repaired=$((repaired + 1))
                ;;
            "$POOL_REPAIR_SKIPPED_STATUS")
                skipped=$((skipped + 1))
                ;;
            *)
                failed=$((failed + 1))
                ;;
        esac
    done

    echo ""
    echo "pool-repair: $repaired repaired, $skipped left alone, $failed failed."

    if [ "$failed" -gt 0 ]; then
        echo ""
        echo "A repair failed, so here is everything the pool can be asked about right now:"
        cmd_pool_diagnose || true
        return 1
    fi

    if [ "$skipped" -gt 0 ]; then
        echo "The ones left alone are in use by a test run. Run this again when it has finished."
    fi
    return 0
}

#
# Prints everything that can be read about every pool emulator, and changes nothing.
#
# This is the reading the 2026-08-09 recovery had to gather by hand, one command at a time, while
# guessing at causes: emulator processes that were resident but burning no CPU, holding no descriptor
# on /dev/kvm or on their tap, listening on no console port and writing nothing to their logs. Four
# explanations were proposed for that and all four were wrong. Nothing here proposes a fifth; it puts
# the facts in one place so the next occurrence is diagnosed from data.
#
# With an index it reports that one alone, which is what the monitor asks for when a run of repairs
# on a single emulator has failed and it wants the account of it in its log before waiting.
# Usage: cmd_pool_diagnose [index]
#
cmd_pool_diagnose() {
    local wanted_index="${1:-}"
    local index unit avd active result main_pid serial uptime pid
    local clock_ticks cpu_seconds log_file
    local indexes

    clock_ticks="$(getconf CLK_TCK 2>/dev/null || echo 100)"

    if [ -n "$wanted_index" ]; then
        case "$wanted_index" in
            ''|*[!0-9]*)
                echo "ERROR: pool-diagnose takes the index of a pool emulator, not '$wanted_index'." >&2
                return 1
                ;;
        esac
        indexes="$wanted_index"
    else
        indexes="$(seq 0 $((PHOTOSPHERE_EMULATOR_COUNT - 1)))"
    fi

    for index in $indexes; do
        unit="$(pool_unit_name "$index")"
        avd="$(pool_avd_name "$index")"
        read -r active result main_pid <<< "$(pool_unit_state "$index")"
        serial="$(pool_serial_for_index "$index")"
        uptime="$(pool_unit_uptime_seconds "$index")"

        echo "================================================================"
        echo "pool index $index: unit $unit, AVD $avd"
        echo "  ActiveState: $active   Result: $result   MainPID: $main_pid"
        echo "  adb serial:  ${serial:-<not attached>}"
        echo "  unit active for: ${uptime:-<not active>} second(s)"

        if command -v systemctl >/dev/null 2>&1; then
            echo "  --- systemctl --user status $unit"
            systemctl --user status "$unit" --no-pager --lines=0 2>&1 | sed 's/^/  /' || true
        fi

        pid="$main_pid"
        if [ "$pid" = "0" ] || [ ! -d "/proc/$pid" ]; then
            echo "  --- no main process to read"
        else
            # utime and stime, in clock ticks, from /proc/<pid>/stat. The command name can contain
            # spaces and brackets, so everything up to and including the closing bracket is dropped
            # first; the remaining fields are the original ones shifted by two, which puts utime at 12
            # and stime at 13.
            cpu_seconds="$(awk -v ticks="$clock_ticks" '{ sub(/^.*\) /, ""); printf "%.1f", ($12 + $13) / ticks }' "/proc/$pid/stat" 2>/dev/null || true)"
            echo "  --- main process $pid"
            echo "  CPU time used: ${cpu_seconds:-<unreadable>} second(s)"

            # A descriptor on /dev/kvm says the emulator got hardware virtualisation, and one on
            # /dev/net/tun says it opened a tap. The tap's own name is not in the link, because the
            # interface is bound with an ioctl after the device is opened, so this says a tap was
            # opened and not which one.
            if ls -l "/proc/$pid/fd" 2>/dev/null | grep -q '/dev/kvm'; then
                echo "  /dev/kvm:      open"
            else
                echo "  /dev/kvm:      NOT open"
            fi
            if ls -l "/proc/$pid/fd" 2>/dev/null | grep -q '/dev/net/tun'; then
                echo "  tap (/dev/net/tun): open"
            else
                echo "  tap (/dev/net/tun): NOT open"
            fi

            if command -v ss >/dev/null 2>&1; then
                echo "  listening sockets:"
                ss -ltnp 2>/dev/null | grep "pid=$pid," | sed 's/^/    /' || echo "    none"
            fi
        fi

        echo "  AVD lock pid(s): $(pool_avd_lock_pids "$avd" | tr '\n' ' ')"

        log_file="$(pool_log_path "pool-$index")"
        if [ -f "$log_file" ]; then
            echo "  --- last 40 lines of $log_file"
            tail -40 "$log_file" 2>/dev/null | sed 's/^/  /' || true
        else
            echo "  --- no log at $log_file"
        fi
    done
}

#
# Prints a one-word verdict on the first line -- "ready" or "not ready" -- with a short reason on
# the next line, and sets the exit code to match (0 = ready, non-zero = not ready) so callers such
# as `test:and` can gate on it.
#
# "ready" means the emulator is started AND on the LAN bridge, i.e. its wlan0 has a 192.168.55.x
# address. That is exactly what the smoke tests need (require_lan_bridge asserts the same thing), so
# this verdict is the truth, not a proxy. Nothing else about the host-side bridge is reported here
# because it misled more than it helped; if you need to debug the setup, inspect with `ip` / `adb`.
#
cmd_status() {
    local adb
    adb="$(adb_path)"
    if [ -z "$adb" ]; then
        echo "not ready"
        echo "  adb not found (looked on PATH and in \${ANDROID_HOME:-\$HOME/Android/Sdk}/platform-tools)"
        return 1
    fi

    # Every emulator/device that is started and booted. adb reports those as "device" (not "offline").
    local serials
    serials="$("$adb" devices 2>/dev/null | awk 'NR > 1 && $2 == "device" { print $1 }')"
    if [ -z "$serials" ]; then
        echo "not ready"
        echo "  emulator not started"
        return 1
    fi

    # On the bridge = a 192.168.55.x address on wlan0. Checked per device, retrying a few times to
    # ride out an adb hiccup or a brief wifi-association gap; a genuinely off-bridge guest never shows
    # the address no matter how often we look. `|| true` keeps `set -o pipefail` from aborting.
    local serial guest attempt ready_count
    ready_count=0
    for serial in $serials; do
        guest=""
        attempt=0
        while [ "$attempt" -lt 3 ]; do
            guest="$(timeout 8 "$adb" -s "$serial" shell ip addr show wlan0 2>/dev/null | tr -d '\r' | awk '/inet 192\.168\.55\./ { print $2 }' || true)"
            if [ -n "$guest" ]; then
                break
            fi
            sleep 1
            attempt=$((attempt + 1))
        done

        if [ -n "$guest" ]; then
            echo "  $serial: on the lan bridge (wlan0 = $guest)"
            ready_count=$((ready_count + 1))
        else
            echo "  $serial: NOT on the lan bridge (started, but wlan0 has no 192.168.55.x address)"
        fi
    done

    if [ "$ready_count" -eq 0 ]; then
        echo "not ready"
        echo "  no emulator is on the lan bridge"
        return 1
    fi

    echo "ready"
    echo "  $ready_count emulator(s) started and on the lan bridge"
    return 0
}

case "${1:-}" in
    up)
        cmd_up
        ;;
    down)
        cmd_down
        ;;
    restart)
        cmd_restart
        ;;
    status)
        cmd_status
        ;;
    pool-up)
        # shift so the sub-command name itself is not passed on as an argument, leaving whatever
        # followed it (--wipe) for cmd_pool_up to read. ${@+"$@"} rather than "$@" for the same
        # reason the setenv array uses that form: on older bash, `set -u` treats an empty "$@" as an
        # unbound variable, and the + form expands to nothing at all instead.
        shift
        cmd_pool_up ${@+"$@"}
        ;;
    pool-down)
        cmd_pool_down
        ;;
    pool-restart)
        cmd_pool_restart
        ;;
    pool-repair)
        # shift for the same reason pool-up does it, leaving --index/--all for cmd_pool_repair.
        shift
        cmd_pool_repair ${@+"$@"}
        ;;
    pool-diagnose)
        shift
        cmd_pool_diagnose ${@+"$@"}
        ;;
    pool-check)
        cmd_pool_check
        ;;
    pool-network)
        # The network precondition on its own, so the monitor can say the bridge is gone and go on
        # waiting for it rather than finding out by attempting a repair. Read-only, and it is the
        # same function pool-repair refuses on.
        require_pool_network
        ;;
    # Internal: the privileged bridge steps, run with sudo by up/down/pool. Not for direct use.
    __bridge-up)
        bridge_up
        ;;
    __bridge-down)
        bridge_down
        ;;
    *)
        echo "Usage: $0 {up|down|restart|status|pool-up [--wipe]|pool-down|pool-restart|pool-repair [--index N|--all]|pool-diagnose}"
        echo ""
        echo "  up          Bring the '$SINGLE_AVD_NAME' emulator up on the LAN bridge and wait"
        echo "              until ready. Runs alongside 'pool-up' without disturbing it."
        echo "  down        Stop that emulator and remove its tap. Leaves a running pool alone."
        echo "  restart     down then up."
        echo "  status      Print each attached device and whether it is on the bridge (exit 0 if any is)."
        echo "  pool-up     Bring up PHOTOSPHERE_EMULATOR_COUNT writable emulators, each on its own"
        echo "              cloned AVD and its own tap. Runs alongside 'up' without disturbing it."
        echo "              Keeps each emulator's userdata, so the installed app survives; pass"
        echo "              --wipe to reset it instead."
        echo "  pool-down   Stop only the pool's emulators and remove only the pool's taps."
        echo "  pool-restart pool-down then pool-up --wipe. Leaves the hand-testing emulator alone."
        echo "              The wipe resets each emulator's data partition to baseline, which is how"
        echo "              a disk-size change takes effect and how a full partition is cleared. The"
        echo "              app is reinstalled on the first 'test:and' afterwards."
        echo "  pool-repair Restart broken pool emulators, one at a time, leaving the bridge and the"
        echo "              taps exactly as they are. Needs no sudo and never prompts. With no"
        echo "              arguments it repairs the emulators it finds broken; --index N repairs one"
        echo "              and --all repairs every one. An emulator a test run is using is skipped."
        echo "              Useless when the taps or the bridge are gone: only pool-up can make those."
        echo "  pool-diagnose"
        echo "              Print everything readable about every pool emulator (unit state, CPU time,"
        echo "              /dev/kvm and tap descriptors, listening sockets, AVD lock pids, log tail)."
        echo "              Read-only."
        echo "  pool-check  One tab-separated line per pool index for a program to read:"
        echo "              index, serial, unit state, uptime, verdict, repair yes/no, reason."
        echo "              Read-only; it is where pool-repair and the monitor both get their verdict."
        echo "  pool-network"
        echo "              Check the bridge, the pool's taps and the DHCP server are in place, and"
        echo "              say what is missing when they are not. Read-only, exit 0 when all present."
        echo ""
        echo "The bridge, DHCP and NAT are shared: they are only torn down once no taps are left."
        echo "Both 'up' and 'pool-up' run on clones of a base AVD, which is auto-selected (override with"
        echo "ANDROID_AVD). See apps/android-frontend/scripts/emulator.md."
        exit 1
        ;;
esac
