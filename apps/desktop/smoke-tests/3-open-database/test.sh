#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && pwd)"
REPO_DIR="$(cd "$DESKTOP_DIR/../.." && pwd)"
CLI_DIR="$REPO_DIR/apps/cli"

source "$TEST_DIR/../lib/common.sh"

print_test_header 3 "open-database"

TMP_DIR="$TEST_DIR/tmp"
APP_PORT=$(find_free_port)

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

log_info "Pre-creating database with CLI..."
cd "$CLI_DIR" && bun run start -- init --db "$TMP_DIR/test-db" --yes
cd "$DESKTOP_DIR"

log_info "Writing databases.toml with one entry..."
mkdir -p "$TMP_DIR/config"
cat > "$TMP_DIR/config/databases.toml" <<EOF
[[databases]]
name = "test-db"
description = ""
path = "$TMP_DIR/test-db"
EOF

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" menu '{"itemId":"open-database"}'
wait_for_log "$TMP_DIR" "Open database dialog opened"

send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}'
wait_for_log "$TMP_DIR" "Database opened"

check_no_errors "$TMP_DIR"

log_success "Test 3 passed: open-database"
