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

# The app has to say it is opening, and then say it opened.
#
# Tapping a database queues a probe task and then a load, and the dialog now stays open, disables
# every entry and spins on the one tapped until the open resolves, rather than closing on the tap and
# leaving the user looking at an empty gallery. The pair of log lines is asserted rather than the
# spinner itself: the state clears as soon as the open finishes, so polling the DOM for it is a race
# the test would lose whenever the open was quick.
wait_for_log "$TMP_DIR" "Opening database:"
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

# --- Restart, and the database the user was in opens again on its own. ---
#
# The database that was open is recorded by the shared code that opens one, so every platform gets
# this by virtue of opening a database. It used to be written by the Electron main process alone,
# read by the shared interface, and so worked here and nowhere else. Nothing failed where it did not
# work: the read returned nothing and the app started with nothing open, which is why it went
# unnoticed for months and why it is asserted now.
stop_app "$APP_PORT" "$TMP_DIR"

# The relaunched app starts a fresh app.log, so the cursor from the first run points past the end of
# it and the wait below would time out on a line that is there.
rm -f "$TMP_DIR/.log-cursor"

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# No command is sent between the app starting and this line. The database opening is the app's own
# doing, which is the whole assertion.
wait_for_log "$TMP_DIR" "Database opened" 60
log_success "The database opened by itself after a restart"

check_no_errors "$TMP_DIR"

log_success "Test 3 passed: open-database"
