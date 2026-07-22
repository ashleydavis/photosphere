#!/usr/bin/env bash
# Connects the Android emulator to a real layer-2 network segment that this host is also on, so LAN
# sharing works between the Electron app on the host and the Photosphere app in the emulator.
#
# Why this is needed:
# By default the emulator runs behind QEMU's user-mode NAT (the 10.0.2.x network). That network is
# deliberately isolated: the guest can reach out through the host, but UDP broadcast never leaves the
# emulator, and the host cannot open a connection back to the guest. LAN sharing depends on both. The
# receiver broadcasts "PSIE_RECV:<port>:<fingerprint>" to 255.255.255.255:54321, and the sender, on
# hearing it, opens an HTTPS connection back to whatever address the broadcast arrived from. Under
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
# Examples:
#   sudo apps/android-frontend/scripts/emulator-lan-bridge.sh up
#   apps/android-frontend/scripts/emulator-lan-bridge.sh status
#   sudo apps/android-frontend/scripts/emulator-lan-bridge.sh down
set -euo pipefail

# Name of the bridge (the virtual switch). Prefixed so it is obvious what created it.
BRIDGE_NAME="br-psphere"

# Name of the tap interface the emulator attaches to.
NETCARD_NAME="emu-netcard"

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
# Brings the segment up. Safe to re-run: every step checks for the state it wants before creating it,
# so running this twice is not an error.
#
cmd_up() {
    require_root "up"
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

    # Create the tap: a virtual NIC whose wire is a file descriptor. The emulator opens it and the
    # guest's ethernet frames come out on the bridge. Owned by your user because the emulator is not
    # root and can only open a tap it owns.
    if ! ip link show "$NETCARD_NAME" >/dev/null 2>&1; then
        ip tuntap add dev "$NETCARD_NAME" mode tap user "$TARGET_USER"
    fi

    # Plug the tap into the bridge and bring it up. Until it has a master it is an unconnected NIC.
    ip link set "$NETCARD_NAME" master "$BRIDGE_NAME"
    ip link set "$NETCARD_NAME" up

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

    echo ""
    echo "Segment is up. Host is $BRIDGE_ADDRESS on $BRIDGE_NAME."
    echo ""
    echo "Now start the emulator attached to it (as $TARGET_USER, not root):"
    echo ""
    echo "  \"\${ANDROID_HOME:-\$HOME/Android/Sdk}/emulator/emulator\" -avd <your-avd> -wifi-tap $NETCARD_NAME"
    echo ""
    echo "Then confirm the guest picked up an address on this segment:"
    echo ""
    echo "  adb shell ip addr show wlan0"
    echo ""
    echo "A 192.168.55.x address means it worked. A 10.0.2.16 address (the emulator's default Wi-Fi"
    echo "address under user-mode NAT) means -wifi-tap did not take."
}

#
# Tears everything down and puts the host's network config back as it was. Safe to re-run.
#
cmd_down() {
    require_root "down"

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

    # Removing the tap detaches it from the bridge as well.
    if ip link show "$NETCARD_NAME" >/dev/null 2>&1; then
        ip link del "$NETCARD_NAME"
        echo "Removed $NETCARD_NAME."
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
# Starts the emulator attached to the bridge. This exists so the -wifi-tap flag is not something you
# have to remember: launching the emulator any other way (Android Studio, a bare `emulator -avd`)
# silently puts it back on the isolated NAT, where LAN sharing cannot work.
#
# Takes an optional AVD name. With no argument it uses the only AVD when there is exactly one, and
# lists them and stops when there is a choice to make.
#
cmd_emulator() {
    # The emulator must run as your login user, because it can only open a tap that it owns and `up`
    # gives the tap to that user. Running it under sudo fails with an unhelpful permissions error.
    if [ "$(id -u)" -eq 0 ]; then
        echo "ERROR: do not run the emulator as root. Run this without sudo." >&2
        exit 1
    fi

    local emulator
    emulator="$(emulator_path)"
    if [ -z "$emulator" ]; then
        echo "ERROR: emulator not found (looked on PATH and in \${ANDROID_HOME:-\$HOME/Android/Sdk}/emulator)." >&2
        exit 1
    fi

    # Fail early with a clear cause rather than letting the emulator start on the isolated NAT and
    # leaving you to work out later why sharing times out.
    if ! ip link show "$NETCARD_NAME" >/dev/null 2>&1; then
        echo "ERROR: $NETCARD_NAME does not exist. Run 'sudo $0 up' first." >&2
        exit 1
    fi

    local avd="${1:-}"
    if [ -z "$avd" ]; then
        local avds
        avds="$("$emulator" -list-avds 2>/dev/null | grep -v '^$' || true)"
        local count
        count="$(echo "$avds" | grep -c . || true)"
        if [ "$count" -eq 1 ]; then
            avd="$avds"
        else
            echo "ERROR: specify which AVD to start. Available:" >&2
            echo "$avds" | sed 's/^/  /' >&2
            echo "" >&2
            echo "Usage: $0 emulator <avd-name>" >&2
            exit 1
        fi
    fi

    echo "Starting '$avd' on $NETCARD_NAME (host is $BRIDGE_ADDRESS)..."
    echo "Check it landed on the segment with: $0 status"
    exec "$emulator" -avd "$avd" -wifi-tap "$NETCARD_NAME" "${@:2}"
}

#
# Reports what is currently set up, for when the emulator cannot see the host and you need to know
# which piece is missing.
#
cmd_status() {
    echo "Bridge:"
    ip -br addr show "$BRIDGE_NAME" 2>/dev/null || echo "  $BRIDGE_NAME does not exist"

    echo ""
    echo "Tap:"
    ip -br link show "$NETCARD_NAME" 2>/dev/null || echo "  $NETCARD_NAME does not exist"

    echo ""
    echo "Bridge ports:"
    ip link show master "$BRIDGE_NAME" 2>/dev/null | awk '/^[0-9]+:/ { sub(/:$/, "", $2); print "  " $2 }' || echo "  none"

    echo ""
    echo "DHCP server:"
    if dnsmasq_running; then
        echo "  running (pid $(cat "$DNSMASQ_PID_FILE")), log at $DNSMASQ_LOG_FILE"
    else
        echo "  not running"
    fi

    echo ""
    echo "Guest address (needs a running emulator):"
    local adb
    adb="$(adb_path)"
    if [ -z "$adb" ]; then
        echo "  adb not found (looked on PATH and in \${ANDROID_HOME:-\$HOME/Android/Sdk}/platform-tools)"
    else
        # `|| true` because adb exits non-zero when no emulator is running, and with `set -o pipefail`
        # that would abort status entirely rather than just reporting no device.
        local guest
        guest="$("$adb" shell ip addr show wlan0 2>/dev/null | awk '/inet / { print $2 }' || true)"
        if [ -z "$guest" ]; then
            echo "  no device, or wlan0 has no address yet"
        else
            echo "  $guest"
        fi
    fi

    # A tap gets carrier only once a process opens its file descriptor, and a bridge stays DOWN
    # while none of its ports have carrier. So both showing DOWN with no emulator running is normal
    # and not a fault. Said explicitly here because it otherwise looks exactly like a broken setup.
    if ! ip link show "$NETCARD_NAME" 2>/dev/null | grep -q "LOWER_UP"; then
        echo ""
        echo "Note: bridge and tap show DOWN / NO-CARRIER because no emulator is attached to the tap"
        echo "yet. That is expected. They come up when you start the emulator with -wifi-tap $NETCARD_NAME."
    fi
}

case "${1:-}" in
    up)
        cmd_up
        ;;
    down)
        cmd_down
        ;;
    status)
        cmd_status
        ;;
    emulator)
        shift
        cmd_emulator "$@"
        ;;
    *)
        echo "Usage: $0 {up|down|status|emulator}"
        echo ""
        echo "  up               Create the bridge/tap and start DHCP, so the emulator can share a network with this host."
        echo "  down             Remove all of it."
        echo "  status           Show what is currently set up and what address the guest has."
        echo "  emulator [avd]   Start the emulator attached to the bridge (no sudo). Pass extra emulator flags after the AVD name."
        echo ""
        echo "See apps/android-frontend/scripts/emulator-lan-bridge.md for the full walkthrough."
        exit 1
        ;;
esac
