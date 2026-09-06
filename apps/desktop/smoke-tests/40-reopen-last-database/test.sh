#!/bin/bash

# The database named by last_database in databases.toml is reopened on launch, and closing it clears
# the key so the next launch lands on the welcome screen instead.
#
# last_database used to live in desktop.toml, which only the Electron main process could write. It is
# in databases.toml now because that file exists in one format on every platform and can be written
# from outside the app, which is what lets a fixture seeded onto a device open on launch. This test
# covers the desktop half: the value is read from the new file, and the close path clears it there
# without disturbing the databases list beside it.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
REPO_DIR="$(cd "$DESKTOP_DIR/../.." && native_pwd)"
CLI_DIR="$REPO_DIR/apps/cli"

print_test_header 40 "reopen-last-database"

cleanup() {
    cleanup_apps "$TMP_DIR"
}
trap cleanup EXIT

FIXTURE_DB="$REPO_DIR/test/dbs/50-assets"
CONFIG_FILE="$TMP_DIR/config/databases.toml"

# A database of the user's own sits beside the fixture so the close path can be shown to clear
# last_database without touching anything else in the file.
log_info "Pre-creating a second database with the CLI..."
cd "$CLI_DIR" && bun run start -- init --db "$TMP_DIR/other-db" --yes || exit 1
cd "$DESKTOP_DIR"

log_info "Writing databases.toml naming the fixture as the last database..."
mkdir -p "$TMP_DIR/config"
cat > "$CONFIG_FILE" <<EOF
recent_database_names = ["50-assets"]
last_database = "$FIXTURE_DB"

[[databases]]
name = "50-assets"
description = ""
path = "$FIXTURE_DB"

[[databases]]
name = "other-db"
description = ""
path = "$TMP_DIR/other-db"
EOF

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# The whole point: the gallery fills with the seeded database without anything being clicked. Nothing
# in this test opens a database, so a pass here can only come from last_database having been read.
wait_for_log "$TMP_DIR" "Gallery loaded: 50 assets" || exit 1

# Close it from the UI and the key goes with it, so the next launch starts on the welcome screen.
# The close item lives in the right sidebar, which has to be opened before it can be clicked.
send_command "$APP_PORT" click '{"dataId":"right-sidebar-button"}' || exit 1

# Waiting for the item itself rather than pausing: a pause that expires early clicks into a drawer
# that has not mounted, and one that expires late costs the difference.
wait_for_value "$APP_PORT" "close-database-button" "Close database" || exit 1
send_command "$APP_PORT" click '{"dataId":"close-database-button"}' || exit 1
wait_for_value "$APP_PORT" "no-database-loaded" "Welcome to Photosphere" || exit 1

# The file is written by the main process after the renderer has already switched screens, so poll
# for it: the welcome screen appearing does not mean the write has landed yet.
last_database_cleared=false
for _attempt in $(seq 1 60); do
    if ! grep -q "last_database" "$CONFIG_FILE"; then
        last_database_cleared=true
        break
    fi
    sleep 0.5
done

if [ "$last_database_cleared" != "true" ]; then
    log_error "last_database is still in $CONFIG_FILE after the database was closed:"
    cat "$CONFIG_FILE"
    exit 1
fi

# Clearing it must not have taken the databases list with it: both entries and the recents are still
# there, which is what proves the close rewrote one field rather than the file.
if ! grep -q 'name = "50-assets"' "$CONFIG_FILE" \
    || ! grep -q 'name = "other-db"' "$CONFIG_FILE" \
    || ! grep -q 'recent_database_names' "$CONFIG_FILE"; then
    log_error "Closing the database damaged the rest of $CONFIG_FILE:"
    cat "$CONFIG_FILE"
    exit 1
fi

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 40 passed: reopen-last-database"
