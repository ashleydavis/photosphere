#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
REPO_DIR="$(cd "$DESKTOP_DIR/../.." && native_pwd)"
CLI_DIR="$REPO_DIR/apps/cli"
IMAGES_DIR="$REPO_DIR/test/multiple-files"

print_test_header 18 "move-file"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

SOURCE_DB="$TMP_DIR/source-db"
DEST_DB="$TMP_DIR/dest-db"

log_info "Pre-creating source database and importing a fixture..."
cd "$CLI_DIR" && bun run start -- init --db "$SOURCE_DB" --yes
cd "$CLI_DIR" && bun run start -- add "$IMAGES_DIR/test-1.jpeg" --db "$SOURCE_DB" --yes

log_info "Pre-creating destination database..."
cd "$CLI_DIR" && bun run start -- init --db "$DEST_DB" --yes
cd "$DESKTOP_DIR"

log_info "Writing databases.toml with both entries..."
mkdir -p "$TMP_DIR/config"
cat > "$TMP_DIR/config/databases.toml" <<EOF
[[databases]]
name = "source-db"
description = ""
path = "$SOURCE_DB"

[[databases]]
name = "dest-db"
description = ""
path = "$DEST_DB"
EOF

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

log_info "Opening source database..."
send_command "$APP_PORT" open-database "{\"path\":\"$SOURCE_DB\"}"
wait_for_log "$TMP_DIR" "Load assets task completed: 1 assets loaded"
log_success "Source database opened with 1 asset"

wait_for_log "$TMP_DIR" "Gallery items rendered"
log_success "Gallery items are in the DOM"

log_info "Selecting the first gallery item..."
# The selection checkbox is hidden (display:none) until selecting mode is on, so
# the item is selected with a long press, the same gesture a user makes.
send_command "$APP_PORT" long-press '{"dataId":"gallery-thumb","nth":0}'

log_info "Opening right sidebar..."
send_command "$APP_PORT" click '{"dataId":"right-sidebar-button"}'

log_info "Clicking Move to dest-db..."
send_command "$APP_PORT" click '{"dataId":"move-to-database-dest-db"}'

wait_for_log "$TMP_DIR" "Move to database completed: 1 asset moved"
log_success "Move to database completed"

log_info "Opening destination database to verify..."
send_command "$APP_PORT" open-database "{\"path\":\"$DEST_DB\"}"
wait_for_log "$TMP_DIR" "Load assets task completed: 1 assets loaded"
log_success "Destination database has 1 asset"

log_info "Opening source database to verify it is empty..."
send_command "$APP_PORT" open-database "{\"path\":\"$SOURCE_DB\"}"
wait_for_log "$TMP_DIR" "Load assets task completed: 0 assets loaded"
log_success "Source database is empty after move"

check_no_errors "$TMP_DIR"

log_success "Test 18 passed: move-file"
