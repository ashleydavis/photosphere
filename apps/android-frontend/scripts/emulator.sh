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

# How many emulators the pool brings up. Only `pool-up` reads this; `up` is always a single emulator.
#
# Reduced from 5 to 3 to lighten the load on the development machine. Five emulators sat at roughly
# 5GB resident each once warm, which together with the test suite left the machine with very little
# headroom, and a run in that state saw four of the five die inside ten minutes. Three is enough for
# the mobile smoke suite to keep running several tests at once; it is slower than five, not broken.
#
# Override with the environment variable to go back up, for example
# PHOTOSPHERE_EMULATOR_COUNT=5 bun run emu:and:pool
PHOTOSPHERE_EMULATOR_COUNT="${PHOTOSPHERE_EMULATOR_COUNT:-3}"

# The tap and AVD names, shared with the smoke-test harness and the run script. Sourced rather than
# repeated, so a rename cannot leave one side looking for an interface or an AVD the other never
# creates. See emulator-config.sh for what each one is for.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/emulator-config.sh"

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

# How long to wait for systemd to release those unit names after their emulators have gone. Seconds,
# because the wait is normally a moment; it is generous only so that a loaded machine is not failed
# for being slow.
POOL_UNIT_RELEASE_TIMEOUT_SECONDS=60

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
disk.dataPartition.size=6G
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
# Usage: start_emulator_bg <avd_name> <tap_name> <log_suffix>
#
start_emulator_bg() {
    local avd="$1"
    local netcard="$2"
    local log_suffix="$3"

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

    local unit="psphere-emu-$log_suffix"

    # A transient unit disappears once it has stopped, but one whose emulator exited non-zero stays
    # behind in the failed state, and starting this name again would collide with it. This clears
    # that leftover record and nothing else: it cannot stop an emulator that is running.
    systemctl --user reset-failed "$unit" 2>/dev/null || true

    echo "Starting emulator '$avd' on $netcard as $unit (cold boot, so wifi associates to the bridge)..."

    # -no-snapshot forces a cold boot. A quick-boot snapshot restores the guest's
    # previous network state (behind the 10.0.2.x virtual router), so wlan0 never
    # re-associates to the freshly created tap and stays NO-CARRIER. A cold boot
    # brings wifi up fresh and associates it to -wifi-tap, which is the whole point.
    #
    # MemoryHigh rather than MemoryMax per emulator: MemoryHigh throttles the emulator and reclaims
    # from it, where MemoryMax would have the kernel kill it outright, and an emulator sits close
    # enough to any ceiling worth setting that a hard kill would be a coin toss. The slice's own
    # MemoryMax is the hard backstop, and it covers the pool rather than one member of it.
    #
    # 5G is a per-emulator sanity check, not the real limit: it sits within the 4GB to 6.4GB range
    # measured of a working emulator, so an emulator behaving normally barely notices it and one
    # running away is slowed down on its own rather than at the expense of the other four. What
    # bounds a test run is the slice, in psphere-pool.slice. Change that file, not this number, to
    # give the pool more or less room.
    #
    # ${setenv_args[@]+"${setenv_args[@]}"} rather than "${setenv_args[@]}" because this script runs
    # under `set -u`, where expanding an empty array is an unbound-variable error on older bash. The
    # + form expands to nothing at all when the array is empty, which is what is wanted.
    # -gpu swiftshader_indirect pins software rendering.
    #
    # Two settings have been tried here and both are recorded, because the second was chosen on
    # evidence produced by the first.
    #
    # "auto", the original, let the emulator pick a backend at runtime. It chose software rendering
    # anyway (Vulkan 'lavapipe', GLES 'swangle'), and four of five pool emulators crashed inside ten
    # minutes during a suite run, each log ending in crash-handler output with a minidump written.
    #
    # "off" was tried next. It removed GPU emulation entirely and produced a new, repeatable failure:
    # the app started, its WebView took fifteen seconds to bring up a sandboxed rendering process,
    # and the main thread then hung with an ANR. Two separate occurrences, both inside WebView
    # start-up, one blocked on a mutex in WebView class initialisation. The devices were healthy
    # throughout, so this was the app hanging rather than the emulator dying. "off" leaves Chromium
    # with no GL path at all, which is what its start-up needs.
    #
    # "swiftshader_indirect" keeps rendering in software, so nothing depends on the host GPU and the
    # backend no longer varies between emulators, while still giving the WebView something to render
    # on. It is the usual choice for unattended runs.
    #
    # Passed on the command line as well as set in the AVD config above, because the command line
    # overrides the config and an AVD cloned before this change would otherwise keep the old setting.
    #
    # None of this has been shown to stop the original crashes. There is no stack trace for those (no
    # minidump symboliser is installed), and the dump has been kept for that. What is established is
    # narrower: "off" causes WebView start-up hangs, and this setting exists to avoid them without
    # going back to a backend chosen at runtime.
    systemd-run --user --unit="$unit" \
        --slice="$POOL_SLICE" \
        --description="Photosphere emulator: $avd on $netcard" \
        -p MemoryHigh=5G \
        -p MemorySwapMax=2G \
        -p StandardOutput="file:/tmp/psphere-emulator-$log_suffix.log" \
        -p StandardError="file:/tmp/psphere-emulator-$log_suffix.log" \
        ${setenv_args[@]+"${setenv_args[@]}"} \
        "$emulator" -avd "$avd" -no-snapshot -no-boot-anim -gpu swiftshader_indirect -wifi-tap "$netcard"
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

    start_emulator_bg "$SINGLE_AVD_NAME" "$netcard" "single"

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
cmd_pool_up() {
    if [ "$(id -u)" -eq 0 ]; then
        echo "ERROR: run 'pool-up' as your user (it uses sudo only for the bridge)." >&2
        exit 1
    fi

    local base
    base="$(ensure_base_avd)" || exit 1
    echo "Cloning the pool's AVDs from '$base'..."

    local index taps=""
    for index in $(seq 0 $((PHOTOSPHERE_EMULATOR_COUNT - 1))); do
        clone_avd "$base" "$(pool_avd_name "$index")" || exit 1
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
        start_emulator_bg "$(pool_avd_name "$index")" "$(pool_netcard_name "$index")" "pool-$index"
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
# which is the one thing it exists to do. `systemctl reset-failed` does not help, because the unit is
# not failed, it is still on its way out.
#
wait_for_pool_units_released() {
    local waited=0

    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi

    while [ "$waited" -lt "$POOL_UNIT_RELEASE_TIMEOUT_SECONDS" ]; do
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
cmd_pool_restart() {
    cmd_pool_down
    cmd_pool_up
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
        cmd_pool_up
        ;;
    pool-down)
        cmd_pool_down
        ;;
    pool-restart)
        cmd_pool_restart
        ;;
    # Internal: the privileged bridge steps, run with sudo by up/down/pool. Not for direct use.
    __bridge-up)
        bridge_up
        ;;
    __bridge-down)
        bridge_down
        ;;
    *)
        echo "Usage: $0 {up|down|restart|status|pool-up|pool-down|pool-restart}"
        echo ""
        echo "  up          Bring the '$SINGLE_AVD_NAME' emulator up on the LAN bridge and wait"
        echo "              until ready. Runs alongside 'pool-up' without disturbing it."
        echo "  down        Stop that emulator and remove its tap. Leaves a running pool alone."
        echo "  restart     down then up."
        echo "  status      Print each attached device and whether it is on the bridge (exit 0 if any is)."
        echo "  pool-up     Bring up PHOTOSPHERE_EMULATOR_COUNT writable emulators, each on its own"
        echo "              cloned AVD and its own tap. Runs alongside 'up' without disturbing it."
        echo "  pool-down   Stop only the pool's emulators and remove only the pool's taps."
        echo "  pool-restart pool-down then pool-up. Leaves the hand-testing emulator alone."
        echo ""
        echo "The bridge, DHCP and NAT are shared: they are only torn down once no taps are left."
        echo "Both 'up' and 'pool-up' run on clones of a base AVD, which is auto-selected (override with"
        echo "ANDROID_AVD). See apps/android-frontend/scripts/emulator.md."
        exit 1
        ;;
esac
