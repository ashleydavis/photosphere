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
# Examples (run as your user; up/down sudo only for the bridge, or use the bun scripts):
#   apps/android-frontend/scripts/emulator.sh up        # bun run emu:and:up
#   apps/android-frontend/scripts/emulator.sh status
#   apps/android-frontend/scripts/emulator.sh restart    # bun run emu:and:restart
#   apps/android-frontend/scripts/emulator.sh down       # bun run emu:and:down
set -euo pipefail

# Name of the bridge (the virtual switch). Prefixed so it is obvious what created it.
BRIDGE_NAME="br-psphere"

# How many emulator instances to bring up. 1 is a single emulator for hand testing; a higher count
# is a pool for the smoke tests to spread work over. Every instance gets its own tap on the bridge.
PHOTOSPHERE_EMULATOR_COUNT="${PHOTOSPHERE_EMULATOR_COUNT:-1}"

# Prefix for the tap interfaces the emulators attach to. One tap per instance, because -wifi-tap
# binds a single emulator to a single tap at launch and cannot be shared.
NETCARD_PREFIX="emu-netcard"

#
# Prints the tap interface name for the given instance index.
#
netcard_name() {
    echo "$NETCARD_PREFIX-$1"
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

    # Create one tap per emulator instance: a virtual NIC whose wire is a file descriptor. The
    # emulator opens it and the guest's ethernet frames come out on the bridge. Owned by your user
    # because the emulator is not root and can only open a tap it owns. One per instance because
    # -wifi-tap binds an emulator to a tap at launch and two emulators cannot share one.
    local index netcard
    for index in $(seq 0 $((PHOTOSPHERE_EMULATOR_COUNT - 1))); do
        netcard="$(netcard_name "$index")"
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

    # Removing a tap detaches it from the bridge as well. Every tap this script has ever created is
    # removed, not just the ones the current count covers, so a teardown after a smaller pool does
    # not strand interfaces from a bigger one.
    local netcard
    for netcard in $(ip -o link show | awk -F': ' '{ print $2 }' | grep "^$NETCARD_PREFIX" || true); do
        ip link del "$netcard"
        echo "Removed $netcard."
    done

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
# True when an emulator/device is attached and reporting "device" (booted, usable) state.
#
device_attached() {
    local adb
    adb="$(adb_path)"
    [ -n "$adb" ] && "$adb" devices 2>/dev/null | awk 'NR > 1 && $2 == "device" { found = 1 } END { exit found ? 0 : 1 }'
}

#
# True when the LAN bridge is fully up: the bridge and tap exist and the DHCP server is running.
#
bridge_is_up() {
    ip link show "$BRIDGE_NAME" >/dev/null 2>&1 \
        && ip link show "$(netcard_name $((PHOTOSPHERE_EMULATOR_COUNT - 1)))" >/dev/null 2>&1 \
        && dnsmasq_running
}

#
# Starts the emulator in the background attached to the tap, so it lands on the bridge. The AVD is
# auto-selected (ANDROID_AVD, else the first one found) -- you do not pass one. Must run as your user,
# not root: the emulator can only open a tap it owns. Detached so it outlives this script; logs to /tmp.
#
start_emulator_bg() {
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

    local avd
    avd="${ANDROID_AVD:-$("$emulator" -list-avds 2>/dev/null | grep -v '^$' | head -1)}"
    if [ -z "$avd" ]; then
        echo "ERROR: no AVD found. Create one in Android Studio's Device Manager." >&2
        exit 1
    fi

    # Several instances of one AVD can only run when every one of them is -read-only, because the
    # AVD's own userdata can have a single writer. A single emulator is left writable so hand testing
    # keeps its state between sessions; a pool is throwaway by nature, so read-only costs nothing.
    local read_only=""
    if [ "$PHOTOSPHERE_EMULATOR_COUNT" -gt 1 ]; then
        read_only="-read-only"
    fi

    local index netcard
    for index in $(seq 0 $((PHOTOSPHERE_EMULATOR_COUNT - 1))); do
        netcard="$(netcard_name "$index")"
        if ! ip link show "$netcard" >/dev/null 2>&1; then
            echo "ERROR: $netcard does not exist; the bridge is not up." >&2
            exit 1
        fi

        echo "Starting emulator $index of $PHOTOSPHERE_EMULATOR_COUNT ('$avd') on $netcard (cold boot, so wifi associates to the bridge)..."

        # -no-snapshot forces a cold boot. A quick-boot snapshot restores the guest's
        # previous network state (behind the 10.0.2.x virtual router), so wlan0 never
        # re-associates to the freshly created tap and stays NO-CARRIER. A cold boot
        # brings wifi up fresh and associates it to -wifi-tap, which is the whole point.
        setsid "$emulator" -avd "$avd" $read_only -no-snapshot -no-boot-anim -wifi-tap "$netcard" \
            >"/tmp/psphere-emulator-$index.log" 2>&1 </dev/null &
    done
}

#
# Prints how many attached devices are on the LAN bridge. Read-only.
#
ready_device_count() {
    local adb serial count
    adb="$(adb_path)"
    count=0
    if [ -z "$adb" ]; then
        echo 0
        return 0
    fi
    for serial in $("$adb" devices 2>/dev/null | awk 'NR > 1 && $2 == "device" { print $1 }'); do
        if timeout 8 "$adb" -s "$serial" shell ip addr show wlan0 2>/dev/null | tr -d '\r' | grep -q 'inet 192\.168\.55\.'; then
            count=$((count + 1))
        fi
    done
    echo "$count"
}

#
# Polls until every requested emulator is ready (started AND on the bridge) or the timeout passes.
#
wait_for_ready() {
    local timeout="${1:-180}"
    local start="$SECONDS"
    local elapsed=0
    local last_note=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if [ "$(ready_device_count)" -ge "$PHOTOSPHERE_EMULATOR_COUNT" ]; then
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

    # A pool needs every instance to be -read-only, and an already-running writable emulator makes
    # that impossible. Refuse rather than kill it: stopping someone's emulator is never this
    # script's call to make. Checked before the bridge setup so it fails immediately instead of
    # asking for a sudo password first.
    if [ "$PHOTOSPHERE_EMULATOR_COUNT" -gt 1 ] && device_attached; then
        echo "" >&2
        echo "An emulator is already running, so a pool of $PHOTOSPHERE_EMULATOR_COUNT cannot start: every" >&2
        echo "instance sharing an AVD must be -read-only, and a running writable one blocks that." >&2
        echo "Stop it first with: bun run emu:and:down" >&2
        exit 1
    fi

    if bridge_is_up; then
        echo "LAN bridge already up."
    else
        echo "Bringing up the LAN bridge (needs sudo)..."
        # Pass GUEST_DNS through: sudo strips the environment, and the bridge setup reads it.
        sudo GUEST_DNS="$GUEST_DNS" "$0" __bridge-up
    fi

    if device_attached; then
        # An emulator is attached. If it is already on the bridge we are done. If it is off the
        # bridge we cannot attach it: -wifi-tap is bound at launch, so a running emulator that is
        # off the bridge can never join it. Do NOT kill it here (up is non-destructive); report it
        # and tell the user to restart. Give a short grace first to ride out a transient gap.
        echo "An emulator is attached; checking whether it is on the bridge..."
        if wait_for_ready 25; then
            cmd_status
            return 0
        fi
        echo "" >&2
        echo "The attached emulator is not on the bridge and cannot be added to it: the -wifi-tap" >&2
        echo "attachment is fixed at launch, so a running emulator that is off the bridge can never" >&2
        echo "join it. This is unrecoverable without a restart." >&2
        echo "Run: bun run emu:and:restart   (or: bun run emu:and:down then bun run emu:and:up)" >&2
        cmd_status >&2 || true
        exit 1
    fi

    start_emulator_bg

    echo "Waiting for $PHOTOSPHERE_EMULATOR_COUNT emulator(s) to be ready on the bridge (up to 300s)..."
    if wait_for_ready 300; then
        cmd_status
    else
        echo "Timed out waiting for the emulator(s) to reach the bridge." >&2
        cmd_status || true
        echo "If an emulator is up but off the bridge, run: bun run emu:and:restart" >&2
        exit 1
    fi
}

#
# Brings everything down: stops the emulator, then tears down the LAN bridge (privileged, via sudo).
#
# Stop the running emulator (if any) and wait for adb to drop it. Leaves the bridge alone;
# both cmd_down (full teardown) and cmd_up (cold-restart of an off-bridge emulator) use this.
stop_emulator() {
    local adb
    adb="$(adb_path)"
    if [ -n "$adb" ] && device_attached; then
        # Every attached emulator, not just the first: a pool leaves several running.
        local serial
        for serial in $("$adb" devices 2>/dev/null | awk 'NR > 1 && $2 == "device" { print $1 }'); do
            echo "Stopping $serial..."
            "$adb" -s "$serial" emu kill >/dev/null 2>&1 || true
        done
        local waited=0
        while [ "$waited" -lt 30 ] && device_attached; do
            sleep 1
            waited=$((waited + 1))
        done
    fi
}

cmd_down() {
    stop_emulator

    if ip link show "$BRIDGE_NAME" >/dev/null 2>&1 || dnsmasq_running; then
        echo "Bringing down the LAN bridge (needs sudo)..."
        sudo "$0" __bridge-down
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
    # Internal: the privileged bridge steps, run with sudo by up/down. Not for direct use.
    __bridge-up)
        bridge_up
        ;;
    __bridge-down)
        bridge_down
        ;;
    *)
        echo "Usage: $0 {up|down|restart|status}"
        echo ""
        echo "  up        Bring the emulator up on the LAN bridge (sets the bridge up automatically, sudo for that part) and wait until ready."
        echo "  down      Stop the emulator and tear the LAN bridge down."
        echo "  restart   down then up."
        echo "  status    Print 'ready' / 'not ready' (exit 0 / non-zero): is the emulator started and on the bridge."
        echo ""
        echo "The AVD is auto-selected (override with ANDROID_AVD). See apps/android-frontend/scripts/emulator.md."
        exit 1
        ;;
esac
