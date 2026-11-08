#!/usr/bin/env bash

# Fails, naming what it found, unless an Android device's default network is Wi-Fi (or Ethernet).
#
# Photosphere's automatic sync is gated on the network: with "Only sync over Wi-Fi" on, which is the default, the app refuses to sync
# while the WebView reports the connection as cellular (packages/api/src/lib/sync-gate.ts). The WebView takes that type from the
# device's default network. An emulator has both a virtual Wi-Fi and a virtual cellular radio, and in one Release Android run the CI
# emulator's default network stayed cellular for the whole run, so the scenarios that need a sync to happen timed out without saying why.
# This makes that precondition a check that fails loudly instead.
#
# Read-only: it only reads `dumpsys connectivity`. It never turns a radio on or off.
#
# Usage: require-wifi-default-network.sh <adb-serial> <wait-seconds>
#   <adb-serial>    The device to read, as `adb devices` lists it (for example emulator-5554).
#   <wait-seconds>  How long to keep reading, once a second, for the default network to become Wi-Fi. 0 reads once.
#
# Exit codes: 0 when the default network is Wi-Fi or Ethernet, 1 when it is anything else (cellular, none) or adb does not answer, 2 when
# the output of dumpsys does not name the default network's transports in a form this script knows.
#
# ANDROID_HOME must name the Android SDK; adb is taken from its platform-tools.

set -u

if [ "$#" -ne 2 ]; then
    echo "Usage: require-wifi-default-network.sh <adb-serial> <wait-seconds>" >&2
    exit 1
fi
serial="$1"
wait_seconds="$2"
if ! [[ "$wait_seconds" =~ ^[0-9]+$ ]]; then
    echo "require-wifi-default-network.sh takes a whole number of seconds to wait, got: $wait_seconds" >&2
    exit 1
fi
if [ -z "${ANDROID_HOME:-}" ]; then
    echo "require-wifi-default-network.sh needs ANDROID_HOME to name the Android SDK, and it is not set." >&2
    exit 1
fi
adb_command="$ANDROID_HOME/platform-tools/adb"

#
# Prints the transports of the default network in the dumpsys text on stdin, as NetworkCapabilities names them ("WIFI", "CELLULAR",
# "WIFI|VPN"), or "none" when the device has no default network. Prints nothing when the text does not say.
#
# ConnectivityService prints "Active default network: <netId>" (or "none") and, after it, "Default network capabilities: [ Transports:
# ... ]". The second line is taken first. Where it is missing, the transports come from that network's own entry in the list of current
# networks, "NetworkAgentInfo{network{<netId>} ... nc{[ Transports: ... ]}".
#
default_network_transports() {
    local dump active net_id capabilities
    dump="$(cat)"
    active="$(printf '%s\n' "$dump" | grep -m1 -E '^[[:space:]]*Active default network:' | sed -E 's/^[[:space:]]*Active default network:[[:space:]]*//')"
    if [ "$active" = "none" ]; then
        echo "none"
        return 0
    fi
    capabilities="$(printf '%s\n' "$dump" | grep -m1 -E '^[[:space:]]*Default network capabilities:')"
    if [ -z "$capabilities" ] && [[ "$active" =~ ^[0-9]+$ ]]; then
        net_id="$active"
        capabilities="$(printf '%s\n' "$dump" | grep -m1 -F "NetworkAgentInfo{network{$net_id}")"
    fi
    printf '%s\n' "$capabilities" | grep -m1 -o -E 'Transports: [A-Z_|]+' | sed -E 's/^Transports: //'
}

deadline=$((SECONDS + wait_seconds))
while true; do
    dump="$(timeout --foreground 30 "$adb_command" -s "$serial" shell dumpsys connectivity 2>&1)"
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "adb -s $serial shell dumpsys connectivity failed (exit $status): $dump" >&2
        exit 1
    fi
    dump="$(printf '%s\n' "$dump" | tr -d '\r')"
    transports="$(printf '%s\n' "$dump" | default_network_transports)"
    if [ -z "$transports" ]; then
        echo "Could not read the default network's transports for $serial from dumpsys connectivity. Its lines naming the default network:" >&2
        printf '%s\n' "$dump" | grep -E 'default network|Default network' >&2
        exit 2
    fi
    case "|$transports|" in
        *"|CELLULAR|"*)
            ;;
        *"|WIFI|"* | *"|ETHERNET|"*)
            echo "The default network of $serial is $transports."
            exit 0
            ;;
    esac
    if [ "$SECONDS" -ge "$deadline" ]; then
        break
    fi
    sleep 1
done

case "|$transports|" in
    *"|CELLULAR|"*)
        echo "The device $serial's default network is cellular ($transports), so the wifi-only sync gate will refuse every automatic sync" >&2
        echo "while \"Only sync over Wi-Fi\" is on (packages/api/src/lib/sync-gate.ts). Put the device on Wi-Fi before running a scenario" >&2
        echo "that needs a sync." >&2
        ;;
    *"|none|"*)
        echo "The device $serial has no default network, so it is offline and the sync gate will refuse every automatic sync." >&2
        ;;
    *)
        echo "The device $serial's default network is $transports, not Wi-Fi, so a scenario that needs a sync cannot rely on it." >&2
        ;;
esac
if [ "$wait_seconds" -gt 0 ]; then
    echo "It was read once a second for ${wait_seconds}s and never became Wi-Fi." >&2
fi
exit 1
