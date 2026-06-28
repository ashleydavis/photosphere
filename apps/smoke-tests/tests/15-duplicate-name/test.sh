#!/bin/bash

# Mobile port of desktop 15-duplicate-name. Adds a secret whose name already exists and expects
# the duplicate-name guard to fire. Desktop seeds the conflicting secret on the host vault; on
# mobile the vault lives on the device, so the precondition needs device-side seeding.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 15 "duplicate-name"

TMP_DIR="$TEST_DIR/tmp"
APP_PORT=$(find_free_port)

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$APP_PORT" "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Seed the conflicting secret so adding one of the same name triggers the duplicate-name guard.
send_command "$APP_PORT" reset-config '{}' || exit 1
send_command "$APP_PORT" seed-secrets '{"secrets":[{"entry":{"name":"dup-secret","type":"api-key"},"value":"existing"}]}' || exit 1

send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
wait_for_log "$TMP_DIR" "Secrets page loaded" 20

send_command "$APP_PORT" click '{"dataId":"add-secret-button"}' || exit 1
wait_for_log "$TMP_DIR" "Add secret dialog opened" 20

send_command "$APP_PORT" type '{"dataId":"secret-name-input","text":"dup-secret"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
wait_for_log "$TMP_DIR" "A secret named 'dup-secret' already exists" 20

log_success "Test 15 passed: duplicate-name"
