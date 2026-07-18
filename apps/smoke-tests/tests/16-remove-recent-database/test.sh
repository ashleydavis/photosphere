#!/bin/bash

# Opens the sidebar and removes a recent database. Electron seeds two databases and
# databases.toml on the host, then asserts recent_database_names vs [[databases]] entries.
# Mobile seeds one recent entry via seed-recent.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 16 "remove-recent-database"

TMP_DIR="$TEST_DIR/tmp"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

if [ "$PLATFORM" = "electron" ]; then
    log_info "Pre-creating two databases with CLI..."
    create_database "$TMP_DIR/test-db-a"
    create_database "$TMP_DIR/test-db-b"

    log_info "Writing databases.toml seeded with two entries and both in recent_database_names..."
    mkdir -p "$TMP_DIR/config"
    cat > "$TMP_DIR/config/databases.toml" <<EOF
recent_database_names = ["test-db-a", "test-db-b"]

[[databases]]
name = "test-db-a"
description = ""
path = "$TMP_DIR/test-db-a"

[[databases]]
name = "test-db-b"
description = ""
path = "$TMP_DIR/test-db-b"
EOF
fi

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

if [ "$PLATFORM" != "electron" ]; then
    send_command "$APP_PORT" reset-config '{}' || exit 1
    create_database "$TMP_DIR/test-db"
    seed_database "$TMP_DIR/test-db" "test-db"
    send_command "$APP_PORT" seed-recent '{"recent":[{"name":"test-db","path":"test-db"}]}' || exit 1
    send_command "$APP_PORT" open-database '{"path":"test-db"}' || exit 1
    wait_for_log "$TMP_DIR" "Load assets task completed: 0 assets loaded"
fi

send_command "$APP_PORT" click '{"dataId":"sidebar-toggle-button"}' || exit 1
sleep 1

send_command "$APP_PORT" click '{"dataId":"remove-recent-database-button-0"}' || exit 1

if [ "$PLATFORM" = "electron" ]; then
    wait_for_log "$TMP_DIR" "Recent database removed: test-db-a"

    log_info "Verifying databases.toml: recent name removed but [[databases]] entry intact..."
    TOML_FILE="$TMP_DIR/config/databases.toml"

    if grep -q "test-db-a" <(grep -A0 "^recent_database_names" "$TOML_FILE"); then
        log_error "test-db-a still present in recent_database_names"
        cat "$TOML_FILE"
        exit 1
    fi

    if ! grep -q "test-db-b" <(grep -A0 "^recent_database_names" "$TOML_FILE"); then
        log_error "test-db-b unexpectedly missing from recent_database_names"
        cat "$TOML_FILE"
        exit 1
    fi

    db_count=$(grep -c "^\[\[databases\]\]" "$TOML_FILE")
    if [ "$db_count" -ne 2 ]; then
        log_error "Expected 2 [[databases]] entries, found $db_count"
        cat "$TOML_FILE"
        exit 1
    fi

    if ! grep -q "path = \"$TMP_DIR/test-db-a\"" "$TOML_FILE"; then
        log_error "test-db-a database entry was unexpectedly removed"
        cat "$TOML_FILE"
        exit 1
    fi
else
    wait_for_log "$TMP_DIR" "Recent database removed"
fi

check_no_errors "$TMP_DIR"

log_success "Test 16 passed: remove-recent-database"
