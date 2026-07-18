#!/bin/bash

# Verifies host ↔ app connectivity that LAN sharing depends on. Every platform
# exercises the control bridge (ready + command round-trip). Android also checks
# adb shell and guest→host ping; those are the paths the emulator uses for share
# traffic.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 28 "host-emulator-comms"

TMP_DIR="$TEST_DIR/tmp"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Host → app: a navigate command must succeed and leave a durable log line.
send_command "$APP_PORT" navigate '{"page":"/about"}' || exit 1
wait_for_log "$TMP_DIR" "test-navigate: navigating to /about"
log_success "Host reaches the app over the control bridge."

# App → host: the bridge already received the ready signal (wait_for_ready) and
# is appending renderer/main logs into app.log; a non-empty log proves the app
# is writing back to the host.
if [ ! -s "$TMP_DIR/app.log" ]; then
    log_error "App did not write any logs back to the host ($TMP_DIR/app.log is empty)."
    exit 1
fi
log_success "App reaches the host (app.log is non-empty)."

if [ "$PLATFORM" = "android" ]; then
    # Host to emulator: adb reaches the guest shell and a token round-trips.
    token="h2g-$$-${RANDOM}"
    result="$(adb shell echo "$token" 2>/dev/null | tr -d '\r')"
    if [ "$result" != "$token" ]; then
        log_error "Host could not reach the emulator over adb (expected '$token', got '$result')."
        exit 1
    fi
    log_success "Host reaches the emulator (adb shell round-trip)."

    # Emulator to host: the guest reaches the host at the same address the app uses for the
    # control bridge (android_host_address): 192.168.55.1 on a bridge-attached emulator,
    # 10.0.2.2 on a NAT one.
    host="$(android_host_address)"
    if ! adb shell ping -c 2 -W 2 "$host" >/dev/null 2>&1; then
        log_error "The emulator could not reach the host at $host."
        exit 1
    fi
    log_success "Emulator reaches the host ($host)."
fi

check_no_errors "$TMP_DIR"

log_success "Test 28 passed: host-emulator-comms"
