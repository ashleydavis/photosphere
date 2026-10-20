#!/bin/bash

# Exercises the sync settings on the Configuration dialog: the master "Enable syncing" toggle and the "Only sync over Wi-Fi" toggle.
# Verifies each toggle recomputes the decision whether syncing is allowed and pushes it to the host (observed via the log line the host writes when it is told,
# which names the new value) and that both values persist to the sync section of config.yaml. On desktop the connection type is
# "unknown" (treated as allowed), so the Wi-Fi-only toggle does not block syncing; this test asserts the decision and persistence
# path, which is the coverage the SyncContext and dialog otherwise lack.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 24 "sync-settings"

trap 'cleanup_apps "$TMP_DIR"' EXIT

#
# Prints the indented body of one top-level section of the config.yaml the app wrote.
#
# The settings are grouped by feature now, and `enabled` appears under both `sync` and `auto_import`, so a match against the whole file
# cannot say which feature it found. Asserting "syncing is off" against the whole file would pass on an app that had written nothing at
# all, because automatic import is off in this test throughout.
#
# The range runs from the section's own line to the next line starting in column one, with both delimiters dropped, so what is left is
# the section's keys.
# Usage: config_section <section-name>
#
config_section() {
    local section="$1"
    read_config_file config.yaml | sed -n "/^${section}:/,/^[^[:space:]]/{ /^${section}:/d; /^[^[:space:]]/d; p; }"
}

#
# Polls one section of config.yaml until it contains a line matching the given extended-regex pattern. The only wait here that is not
# one of the shared ones, because it watches a file the app writes rather than the app itself.
# Usage: wait_for_config <section-name> <ere-pattern>
#
wait_for_config() {
    local section="$1"
    local pattern="$2"
    local deadline=$((SECONDS + DEFAULT_WAIT_TIMEOUT))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if config_section "$section" | grep -Eq "$pattern"; then
            return 0
        fi
        sleep "$WAIT_POLL_INTERVAL"
    done
    log_error "Timed out waiting for pattern '$pattern' in the $section section of config.yaml"
    read_config_file config.yaml
    exit 1
}

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# On startup the SyncContext mounts and pushes its computed decision to the host. With the defaults (syncing enabled, online) syncing
# is allowed.
wait_for_log "$TMP_DIR" "Sync gate set to true"

# Open the Configuration dialog and confirm the sync settings rendered.
click_sidebar_item "$APP_PORT" configuration || exit 1
wait_for_value "$APP_PORT" "configuration-dialog" "Syncing"

# Turning off "Enable syncing" disallows syncing and persists syncEnabled=false.
send_command "$APP_PORT" click '{"dataId":"sync-enabled-toggle"}' || exit 1
wait_for_log "$TMP_DIR" "Sync gate set to false"
wait_for_config "sync" "^[[:space:]]+enabled:[[:space:]]*false"

# Turning it back on allows syncing again and persists syncEnabled=true.
send_command "$APP_PORT" click '{"dataId":"sync-enabled-toggle"}' || exit 1
wait_for_log "$TMP_DIR" "Sync gate set to true"
wait_for_config "sync" "^[[:space:]]+enabled:[[:space:]]*true"

# Turning off "Only sync over Wi-Fi" persists the flag. On desktop the connection type is "unknown", so syncing stays allowed (the
# toggle only restricts cellular on mobile).
send_command "$APP_PORT" click '{"dataId":"sync-wifi-only-toggle"}' || exit 1
wait_for_log "$TMP_DIR" "Sync gate set to true"
wait_for_config "sync" "^[[:space:]]+only_on_wifi:[[:space:]]*false"

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 24 passed: sync-settings"
