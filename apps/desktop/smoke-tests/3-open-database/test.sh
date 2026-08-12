#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
REPO_DIR="$(cd "$DESKTOP_DIR/../.." && native_pwd)"
CLI_DIR="$REPO_DIR/apps/cli"

print_test_header 3 "open-database"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

log_info "Pre-creating database with CLI..."
cd "$CLI_DIR" && bun run start -- init --db "$TMP_DIR/test-db" --yes || exit 1
cd "$DESKTOP_DIR"

log_info "Writing databases.toml with one entry..."
mkdir -p "$TMP_DIR/config"
cat > "$TMP_DIR/config/databases.toml" <<EOF
[[databases]]
name = "test-db"
description = ""
path = "$TMP_DIR/test-db"
EOF

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" menu '{"itemId":"open-database"}'
wait_for_log "$TMP_DIR" "Open database dialog opened"

send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}'
wait_for_log "$TMP_DIR" "Database opened"

# Open the Database Summary page through the sidebar's "Database Info" link and check it reports the
# database mode. The database was just created by the CLI and holds all its files, so full is the
# only correct answer.
log_info "Opening the left sidebar..."
send_command "$APP_PORT" click '{"dataId":"sidebar-toggle-button"}'

# Wait for the drawer to mount and its links to render. Waiting for the link this test is about to
# click is both quicker than a fixed pause and stricter: a pause that expired early clicked into a
# drawer that was not there yet, and one that expired late cost the difference.
wait_for_value "$APP_PORT" "sidebar-database-summary" "Database Info"

send_command "$APP_PORT" click '{"dataId":"sidebar-database-summary"}'
wait_for_log "$TMP_DIR" "Database summary loaded:"
wait_for_value "$APP_PORT" database-mode "full"

check_no_errors "$TMP_DIR"

log_success "Test 3 passed: open-database"
