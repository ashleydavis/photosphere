#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
REPO_DIR="$(cd "$DESKTOP_DIR/../.." && native_pwd)"
CLI_DIR="$REPO_DIR/apps/cli"

print_test_header 16 "remove-recent-database"

TMP_DIR="$TEST_DIR/tmp"
APP_PORT=$(find_free_port)

cleanup() {
    if [ -f "$TMP_DIR/app.pid" ]; then
        local pid
        pid=$(cat "$TMP_DIR/app.pid")
        kill "$pid" 2>/dev/null || true
        sleep 0.5
        kill -9 "$pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

log_info "Pre-creating two databases with CLI..."
cd "$CLI_DIR" && bun run start -- init --db "$TMP_DIR/test-db-a" --yes
cd "$CLI_DIR" && bun run start -- init --db "$TMP_DIR/test-db-b" --yes
cd "$DESKTOP_DIR"

log_info "Writing databases.toml seeded with two entries and both in recent_database_paths..."
mkdir -p "$TMP_DIR/config"
cat > "$TMP_DIR/config/databases.toml" <<EOF
recent_database_paths = ["$TMP_DIR/test-db-a", "$TMP_DIR/test-db-b"]

[[databases]]
name = "test-db-a"
description = ""
path = "$TMP_DIR/test-db-a"

[[databases]]
name = "test-db-b"
description = ""
path = "$TMP_DIR/test-db-b"
EOF

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

log_info "Opening the left sidebar..."
send_command "$APP_PORT" click '{"dataId":"sidebar-toggle-button"}'

# Wait for the drawer to mount and the recent databases list to render.
sleep 1

log_info "Clicking the trash icon for the first recent database..."
send_command "$APP_PORT" click '{"dataId":"remove-recent-database-button-0"}'

wait_for_log "$TMP_DIR" "Recent database removed: $TMP_DIR/test-db-a"

log_info "Verifying databases.toml: recent path removed but [[databases]] entry intact..."
TOML_FILE="$TMP_DIR/config/databases.toml"

if grep -q "test-db-a" <(grep -A0 "^recent_database_paths" "$TOML_FILE"); then
    log_error "test-db-a still present in recent_database_paths"
    cat "$TOML_FILE"
    exit 1
fi

if ! grep -q "test-db-b" <(grep -A0 "^recent_database_paths" "$TOML_FILE"); then
    log_error "test-db-b unexpectedly missing from recent_database_paths"
    cat "$TOML_FILE"
    exit 1
fi

# Both [[databases]] entries must still be present.
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

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 16 passed: remove-recent-database"
