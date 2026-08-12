#!/bin/bash

# Exercises automatic import end to end in the real app: switching it on creates the default private
# database, lists it, and marks it as the default; a file dropped into a watched folder is imported
# without the user doing anything; and the cleanup toggle deletes the source file once the photo is
# confirmed in the database.
#
# The watched folder is set through the config file rather than through the folder picker, because a
# native folder dialog cannot be driven from here. Everything above the picker is the real code path:
# the setting, the main process reacting to it, the task, and the import.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
REPO_DIR="$(cd "$DESKTOP_DIR/../.." && native_pwd)"

print_test_header 35 "auto-import"

CONFIG_TOML="$TMP_DIR/config/desktop.toml"
WATCH_DIR="$TMP_DIR/watched-photos"
DEFAULT_DB_DIR="$TMP_DIR/electron-user-data/photosphere-default"

cleanup() {
    cleanup_apps "$TMP_DIR"
}
trap cleanup EXIT

#
# Polls a TOML file until it contains a line matching the given extended-regex pattern.
#
wait_for_toml() {
    local file="$1"
    local pattern="$2"
    local elapsed=0
    while [ "$elapsed" -lt 30 ]; do
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

#
# Waits until the default database holds at least the given number of originals.
#
wait_for_asset_count() {
    local expected="$1"
    local elapsed=0
    while [ "$elapsed" -lt 90 ]; do
        local actual
        actual=$(ls -1 "$DEFAULT_DB_DIR/asset" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$actual" -ge "$expected" ]; then
            log_success "The default database holds $actual original(s)"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    log_error "The default database never reached $expected original(s)"
    ls -la "$DEFAULT_DB_DIR" 2>/dev/null || true
    exit 1
}

#
# Waits until a file has gone.
#
wait_for_file_gone() {
    local file="$1"
    local elapsed=0
    while [ "$elapsed" -lt 90 ]; do
        if [ ! -e "$file" ]; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    log_error "The source file was still there after 90s: $file"
    exit 1
}

mkdir -p "$WATCH_DIR"

# The folder to watch is written before the app starts, so switching automatic import on has
# somewhere to look that this test controls rather than the machine's own photo folders.
mkdir -p "$TMP_DIR/config"
cat > "$CONFIG_TOML" <<TOMLEOF
[[auto_import_sources]]
type = "folder"
path = "$WATCH_DIR"
recurse = true
TOMLEOF

# The default photo database goes under Electron's user data directory, which none of the
# PHOTOSPHERE_* variables cover. Redirected here so this test writes inside its own directory rather
# than into the real user's, which every other run on this machine would share.
EXTRA_APP_ARGS=(--user-data-dir="$TMP_DIR/electron-user-data")

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# --- 1. Switching automatic import on creates the default database. ---

send_command "$APP_PORT" menu '{"itemId":"open-configuration"}'
wait_for_value "$APP_PORT" "configuration-dialog" "Automatic import"
log_success "The automatic import card is on the configuration dialog"

send_command "$APP_PORT" click '{"dataId":"auto-import-toggle"}'

# The main process reacts to the config write before the renderer logs its own event, and
# wait_for_log only ever looks forward from the last line it matched, so these are waited for in the
# order they are actually written.
wait_for_log "$TMP_DIR" "Creating the default photo database"
wait_for_log "$TMP_DIR" "Starting automatic import into"
wait_for_log "$TMP_DIR" "Automatic import enabled"

wait_for_toml "$CONFIG_TOML" "auto_import_enabled[[:space:]]*=[[:space:]]*true"
wait_for_toml "$CONFIG_TOML" "default_database_path"

if [ ! -f "$DEFAULT_DB_DIR/.db/files.dat" ]; then
    log_error "The default database was not created at $DEFAULT_DB_DIR"
    ls -la "$TMP_DIR/electron-user-data" 2>/dev/null || true
    exit 1
fi
log_success "The default private database was created"

# --- 2. It is listed, and marked as the default. ---

send_command "$APP_PORT" navigate '{"page":"databases"}'
wait_for_log "$TMP_DIR" "Databases page loaded"
wait_for_value "$APP_PORT" "database-default-badge-0" "Default"
log_success "The default database is listed and badged as the default"

# --- 3. A file appearing in the watched folder is imported on its own. ---

cp "$REPO_DIR/test/test.png" "$WATCH_DIR/arrived.png"
log_info "Dropped a photo into the watched folder"

wait_for_asset_count 1

# --- 4. The cleanup toggle deletes the source file once the photo is confirmed. ---

send_command "$APP_PORT" menu '{"itemId":"open-configuration"}'
wait_for_value "$APP_PORT" "configuration-dialog" "Automatic import"

send_command "$APP_PORT" click '{"dataId":"auto-import-cleanup-toggle"}'

# Changing a setting restarts the task with the new one, which is what makes the change take effect
# without a restart of the app.
wait_for_log "$TMP_DIR" "Starting automatic import into"
wait_for_log "$TMP_DIR" "Automatic import cleanup enabled"
wait_for_toml "$CONFIG_TOML" "auto_import_cleanup_enabled[[:space:]]*=[[:space:]]*true"

cp "$REPO_DIR/test/test.jpg" "$WATCH_DIR/cleaned-up.jpg"
log_info "Dropped a second photo, with cleanup switched on"

wait_for_asset_count 2
wait_for_file_gone "$WATCH_DIR/cleaned-up.jpg"
log_success "The source file was deleted once the photo was in the database"

check_no_errors "$TMP_DIR"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 35 passed: auto-import"
