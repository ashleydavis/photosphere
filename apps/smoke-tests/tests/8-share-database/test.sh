#!/bin/bash

# Mobile port of desktop 8-share-database. Like 7-share-secret, the desktop test runs two app
# windows; this port drives the sender side only (single emulator/simulator): it adds a database
# entry, opens the share flow, and waits for a pairing code, surfacing whether the sender-side
# LAN database share flow works on mobile. The full two-party transfer needs two devices and
# native networking (a later layer); until then the sender shows its pairing code and the
# background discovery task waits and times out gracefully.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 8 "share-database"

TMP_DIR="$TEST_DIR/tmp"
DB_NAME="test-db"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Clean slate, then create an empty database and seed it into the app sandbox, and add a database
# entry so the Databases page has a row with a Share button to click. Adding auto-opens the
# database, so the (empty) database must be present to load cleanly.
send_command "$APP_PORT" reset-config '{}' || exit 1
create_database "$TMP_DIR/$DB_NAME"
"${PLATFORM}_seed_database" "$TMP_DIR/$DB_NAME" "$DB_NAME"

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded" 20

send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add database dialog opened" 20

send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"My Test DB"}' || exit 1
send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$DB_NAME\"}" || exit 1
send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Database entry added" 20

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded" 20

send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"share-database-button"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"share-database-send-button"}' || exit 1

log_info "Waiting for pairing code..."
code=""
elapsed=0
while [ "$elapsed" -lt 20 ]; do
    response=$(curl -sf "http://localhost:$APP_PORT/get-value?dataId=share-pairing-code" 2>/dev/null || true)
    code=$(echo "$response" | sed 's/.*"value":"\([^"]*\)".*/\1/')
    if [ -n "$code" ] && echo "$code" | grep -qE '^[0-9]{4}$'; then
        break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done

if [ -z "$code" ] || ! echo "$code" | grep -qE '^[0-9]{4}$'; then
    log_error "Failed to read pairing code from sender (LAN database sharing not working on mobile)"
    exit 1
fi
log_info "Pairing code: $code"

check_no_errors "$TMP_DIR"

log_success "Test 8 passed: share-database (sender side)"
