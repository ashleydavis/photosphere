#!/bin/bash

# Verifies the host and the Android emulator can communicate, in both directions. This is the
# connectivity LAN sharing depends on; the LAN-share tests themselves are separate.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 28 "host-emulator-comms"

# Host to emulator: adb reaches the guest shell and a token round-trips.
token="h2g-$$-${RANDOM}"
result="$(adb shell echo "$token" 2>/dev/null | tr -d '\r')"
if [ "$result" != "$token" ]; then
    log_error "Host could not reach the emulator over adb (expected '$token', got '$result')."
    exit 1
fi
log_success "Host reaches the emulator (adb shell round-trip)."

# Emulator to host: the guest reaches the host at the same address the app uses for the control
# bridge (android_host_address): 192.168.55.1 on a bridge-attached emulator, 10.0.2.2 on a NAT one.
# Hardcoding 10.0.2.2 here would wrongly fail on the bridge, where that alias is dead.
host="$(android_host_address)"
if ! adb shell ping -c 2 -W 2 "$host" >/dev/null 2>&1; then
    log_error "The emulator could not reach the host at $host."
    exit 1
fi
log_success "Emulator reaches the host ($host)."

log_success "Test 28 passed: host-emulator-comms"
