#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
REPO_DIR="$(cd "$DESKTOP_DIR/../.." && native_pwd)"
CLI_DIR="$REPO_DIR/apps/cli"
IMAGES_DIR="$REPO_DIR/test/multiple-files"

print_test_header 4 "import-photos"

TMP_DIR="$TEST_DIR/tmp"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

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

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" menu '{"itemId":"open-database"}'
wait_for_log "$TMP_DIR" "Open database dialog opened"

send_command "$APP_PORT" click '{"dataId":"database-list-item-0"}'
# "Load assets task completed" only fires after the database opens, so it confirms the open on its
# own. Do not also wait for the main-process "Database opened" event first: it is written to app.log
# on a different path than the IPC-forwarded renderer logs, so under load it can land after this
# line, advancing wait_for_log's cursor past it and causing a spurious timeout.
wait_for_log "$TMP_DIR" "Load assets task completed: 0 assets loaded"

send_command "$APP_PORT" click '{"dataId":"import-button"}'
wait_for_log "$TMP_DIR" "Import page ready"

send_command "$APP_PORT" drop "{\"dataId\":\"import-drop-zone\",\"paths\":[\"$IMAGES_DIR/test-1.jpeg\",\"$IMAGES_DIR/test-2.png\"]}"

wait_for_log "$TMP_DIR" "2 assets imported"

send_command "$APP_PORT" navigate '{"page":"/"}'
wait_for_log "$TMP_DIR" "Gallery loaded: 2 assets"

check_no_errors "$TMP_DIR"

log_success "Test 4 passed: import-photos"
