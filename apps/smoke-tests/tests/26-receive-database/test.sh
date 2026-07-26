#!/bin/bash

# Receive a database over the LAN through the REAL Receive Database dialog, from a REAL sender: the
# psi CLI running on the host. The app on the device is the receiver, so the transfer crosses the
# host-to-guest LAN bridge and exercises two independent implementations of the protocol (the Node
# CLI sender against the mobile receiver), not the app talking to itself over loopback.
#
# It asserts the received database is really in the databases list, which only holds once
# importSharePayload is implemented on mobile: the empty stub reports success but persists nothing,
# so this test fails against it.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 26 "receive-database"

TMP_DIR="$TEST_DIR/$TEST_TMP_NAME"

# A host-side sender can only reach the device's receiver over the LAN bridge. Checked before the
# stop_app trap is armed, so failing here does not run a teardown for an app that never started.
require_lan_bridge

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

# Seed the host CLI with the database to send and the geocoding secret it carries, in a vault and
# config isolated under this test's tmp dir so the developer's real keychain and database list are
# untouched. The secret must exist before `dbs add --geocoding-key` will accept it.
log_info "Seeding the host CLI with the database to send..."
run_cli "$TMP_DIR" secrets add --yes --name received-geo-key --type api-key --value received-geo-value >/dev/null 2>&1
run_cli "$TMP_DIR" dbs add --yes --name received-db --description "Received over LAN" --path "$TMP_DIR/received-db" --geocoding-key received-geo-key >/dev/null 2>&1

start_app "$TMP_DIR" || exit 1
wait_for_ready "$APP_PORT" || exit 1

# Clean slate so no pre-existing database or secret collides with the received one.
send_command "$APP_PORT" reset-config '{}' || exit 1

send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
wait_for_log "$TMP_DIR" "Databases page loaded"

# Open the Receive Database dialog from the page-actions menu (a secondary action on mobile).
send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"receive-database-button"}' || exit 1
wait_for_log "$TMP_DIR" "Receive database dialog opened"

# Enter the pairing code the host sender uses, then start hosting the receiver. From here the device
# broadcasts its availability on the LAN and the host CLI discovers it.
send_command "$APP_PORT" type '{"dataId":"receive-database-code-input","text":"4321"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"receive-database-start-button"}' || exit 1

# Give the receiver a moment to begin broadcasting, then send from the host with the real CLI.
sleep 3
log_info "Sending the database from the host CLI..."
cli_send_expect_success "$TMP_DIR" dbs send --yes --name received-db --code 4321

# The receiver hands the delivered payload to the review step.
wait_for_log "$TMP_DIR" "Database review step"

# Save the reviewed database. On a clean slate there is no secret or name conflict, so this imports.
send_command "$APP_PORT" click '{"dataId":"receive-database-save-button"}' || exit 1
wait_for_log "$TMP_DIR" "Database imported"

# On mobile the dialog is a drawer that stays mounted (visibility hidden) on its success step over the
# page, so close it before reading the databases list behind it.
send_command "$APP_PORT" click '{"dataId":"receive-database-close-button"}' || exit 1

# The imported database must really be in the list (importSharePayload actually persisted the entry).
# The app-context refreshes the list after import, so poll until the new row appears.
wait_for_value "$APP_PORT" "database-row-name-received-db" "received-db"

check_no_errors "$TMP_DIR"

log_success "Test 26 passed: receive-database (real CLI sender, real receive UI)"
