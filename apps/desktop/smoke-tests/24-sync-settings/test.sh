#!/bin/bash

# Exercises the sync settings on the Configuration dialog: the master "Enable syncing"
# toggle and the "Only sync over Wi-Fi" toggle. Verifies each toggle recomputes the sync
# gate and pushes it to the host (observed via the "Sync gate set to <bool>" log) and that
# both values persist to desktop.toml. On desktop the connection type is "unknown" (treated
# as allowed), so the Wi-Fi-only toggle does not block syncing; this test asserts the gate
# and persistence path, which is the coverage the SyncContext and dialog otherwise lack.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"

print_test_header 24 "sync-settings"

CONFIG_TOML="$TMP_DIR/config/desktop.toml"

cleanup() {
    cleanup_apps "$TMP_DIR"
}
trap cleanup EXIT

#
# Polls get-value for the given data-id until its value contains the expected substring.
# Usage: wait_for_value <port> <data-id> <expected-substring>
#
wait_for_value() {
    local port="$1"
    local data_id="$2"
    local expected="$3"
    local elapsed=0
    while [ "$elapsed" -lt 30 ]; do
        local response
        response=$(curl -sf "http://localhost:$port/get-value?dataId=$data_id" 2>/dev/null || true)
        if echo "$response" | grep -q "$expected"; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    log_error "Timed out waiting for data-id '$data_id' to contain '$expected' (last response: $response)"
    exit 1
}

#
# Polls a TOML file until it contains a line matching the given extended-regex pattern.
# Usage: wait_for_toml <file> <ere-pattern>
#
wait_for_toml() {
    local file="$1"
    local pattern="$2"
    local elapsed=0
    while [ "$elapsed" -lt 15 ]; do
        if [ -f "$file" ] && grep -Eq "$pattern" "$file"; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    log_error "Timed out waiting for pattern '$pattern' in $file"
    [ -f "$file" ] && cat "$file"
    exit 1
}

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# On startup the SyncContext mounts and pushes its computed gate to the host. With the
# defaults (syncing enabled, online) the gate opens.
wait_for_log "$TMP_DIR" "Sync gate set to true"

# Open the Configuration dialog and confirm the sync settings rendered.
send_command "$APP_PORT" menu '{"itemId":"open-configuration"}'
wait_for_value "$APP_PORT" "configuration-dialog" "Syncing"

# Turning off "Enable syncing" closes the gate and persists syncEnabled=false.
send_command "$APP_PORT" click '{"dataId":"sync-enabled-toggle"}'
wait_for_log "$TMP_DIR" "Sync gate set to false"
wait_for_toml "$CONFIG_TOML" "sync_enabled[[:space:]]*=[[:space:]]*false"

# Turning it back on reopens the gate and persists syncEnabled=true.
send_command "$APP_PORT" click '{"dataId":"sync-enabled-toggle"}'
wait_for_log "$TMP_DIR" "Sync gate set to true"
wait_for_toml "$CONFIG_TOML" "sync_enabled[[:space:]]*=[[:space:]]*true"

# Turning off "Only sync over Wi-Fi" persists the flag. On desktop the connection type is
# "unknown", so the gate stays open (the toggle only restricts cellular on mobile).
send_command "$APP_PORT" click '{"dataId":"sync-wifi-only-toggle"}'
wait_for_log "$TMP_DIR" "Sync gate set to true"
wait_for_toml "$CONFIG_TOML" "sync_only_on_wifi[[:space:]]*=[[:space:]]*false"

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 24 passed: sync-settings"
