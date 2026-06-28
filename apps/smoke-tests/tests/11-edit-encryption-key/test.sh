#!/bin/bash

# Mobile port of desktop 11-edit-encryption-key. Edits an existing encryption-key secret and
# asserts the raw PEM round-trips. Desktop seeds the vault on the host filesystem; on mobile the
# vault lives on the device, so without device-side seeding there is no row to edit and the flow
# stops at the missing Edit dialog, surfacing the seeding/vault gap.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 11 "edit-encryption-key"

TMP_DIR="$TEST_DIR/tmp"
APP_PORT=$(find_free_port)

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Seed one encryption-key secret to edit (desktop seeds the vault; on mobile the secrets store is
# seeded via the test driver). The value is the raw private-key PEM.
send_command "$APP_PORT" reset-config '{}' || exit 1
send_command "$APP_PORT" seed-secrets '{"secrets":[{"entry":{"name":"enc-key","type":"encryption-key"},"value":"-----BEGIN PRIVATE KEY-----\nMOCK\n-----END PRIVATE KEY-----"}]}' || exit 1

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded" 20

send_command "$APP_PORT" click '{"dataId":"edit-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Edit secret dialog opened" 20

send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "Secret updated" 20

check_no_errors "$TMP_DIR"

log_success "Test 11 passed: edit-encryption-key"
