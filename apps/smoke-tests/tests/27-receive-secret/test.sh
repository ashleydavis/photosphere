#!/bin/bash

# Receive a standalone secret over the LAN through the REAL Receive Secret dialog, from a REAL sender:
# the psi CLI running on the host. The companion of 26-receive-database for the secret path
# (receive-secret-dialog.tsx). The app on the device is the receiver, so the transfer crosses the
# host-to-guest LAN bridge between two independent implementations of the protocol.
#
# It asserts the received secret is really in the secrets list, which only holds once
# importSharePayload is implemented on mobile: the empty stub reports success but persists nothing,
# so this test fails against it.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 27 "receive-secret"

TMP_DIR="$TEST_DIR/$TEST_TMP_NAME"

# A host-side sender can only reach the device's receiver over the LAN bridge. Checked before the
# stop_app trap is armed, so failing here does not run a teardown for an app that never started.
require_lan_bridge

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

# Seed the host CLI with the secret to send, in a vault isolated under this test's tmp dir so the
# developer's real keychain is untouched.
log_info "Seeding the host CLI with the secret to send..."
run_cli "$TMP_DIR" secrets add --yes --name received-secret --type api-key --value received-secret-value >/dev/null 2>&1

start_app "$TMP_DIR" || exit 1
wait_for_ready "$APP_PORT" || exit 1

# Clean slate so no pre-existing secret collides with the received one.
send_command "$APP_PORT" reset-config '{}' || exit 1

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded"

# Open the Receive Secret dialog from the page-actions menu (a secondary action on mobile).
send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"receive-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Receive secret dialog opened"

# Enter the pairing code the host sender uses, then start hosting the receiver. From here the device
# broadcasts its availability on the LAN and the host CLI discovers it.
send_command "$APP_PORT" type '{"dataId":"receive-secret-code-input","text":"4321"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"receive-secret-start-button"}' || exit 1

# Give the receiver a moment to begin broadcasting, then send from the host with the real CLI.
sleep 3
log_info "Sending the secret from the host CLI..."
cli_send_expect_success "$TMP_DIR" secrets send --yes --name received-secret --code 4321

# The receiver hands the delivered payload to the review step.
wait_for_log "$TMP_DIR" "Secret review step"

# Save the reviewed secret under the sender-provided name.
send_command "$APP_PORT" click '{"dataId":"receive-secret-save-button"}' || exit 1
wait_for_log "$TMP_DIR" "Secret saved"

# On mobile the dialog is a drawer that stays mounted on its success step over the page, so close it
# before reading the secrets list behind it.
send_command "$APP_PORT" click '{"dataId":"receive-secret-close-button"}' || exit 1

# The imported secret must really be in the list (importSharePayload actually persisted it through
# configStore). The app-context refreshes the list after import, so poll until the new row appears.
wait_for_value "$APP_PORT" "secret-row-name-received-secret" "received-secret"

check_no_errors "$TMP_DIR"

log_success "Test 27 passed: receive-secret (real CLI sender, real receive UI)"
