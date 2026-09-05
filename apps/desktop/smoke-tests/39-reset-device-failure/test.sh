#!/bin/bash

# Proves a reset that cannot finish says so, loudly, and stops.
#
# The dangerous failure for this feature is a quiet one: a user hands a phone or a laptop on believing
# their credentials went, when the reset stopped half way through. So the reset throws rather than
# swallowing anything, and the dialog turns that into a toast that does not auto-dismiss.
#
# The failure is provoked from outside the app, with no test-only code in it: the vault file is
# replaced with something that is not JSON, which is exactly what a truncated write or a damaged disk
# leaves behind. Reading the vault then fails, so the reset fails at the secrets step, after the
# database entries have gone and before the app's own storage is emptied. That last part is what the
# final assertion checks: the reset stopped where it broke instead of carrying on regardless.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"
TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"
REPO_DIR="$(cd "$DESKTOP_DIR/../.." && native_pwd)"
CLI_DIR="$REPO_DIR/apps/cli"

print_test_header 39 "reset-device-failure"

VAULT_FILE="$TMP_DIR/vault/vault.json"

cleanup() {
    cleanup_apps "$TMP_DIR"
}
trap cleanup EXIT

log_info "Pre-creating database with CLI..."
cd "$CLI_DIR" && bun run start -- init --db "$TMP_DIR/test-db" --yes || exit 1
cd "$DESKTOP_DIR"

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# A database entry and a secret, so the reset has real work to do before it hits the damaged vault.
send_command "$APP_PORT" navigate '{"page":"databases"}'
wait_for_log "$TMP_DIR" "Databases page loaded"
send_command "$APP_PORT" click '{"dataId":"add-database-button"}'
wait_for_log "$TMP_DIR" "Add database dialog opened"
send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"My Test DB"}'
send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$TMP_DIR/test-db\"}"
send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}'
wait_for_log "$TMP_DIR" "Database entry added"

send_command "$APP_PORT" navigate '{"page":"secrets"}'
wait_for_log "$TMP_DIR" "Secrets page loaded"
send_command "$APP_PORT" click '{"dataId":"add-secret-button"}'
wait_for_log "$TMP_DIR" "Add secret dialog opened"
send_command "$APP_PORT" type '{"dataId":"secret-name-input","text":"test-secret"}'
send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}'
wait_for_log "$TMP_DIR" "Secret added"

# Damage the vault, the way a truncated write would.
if [ ! -f "$VAULT_FILE" ]; then
    log_error "No vault file at $VAULT_FILE to damage; the secret was never stored"
    exit 1
fi
printf '%s' 'this is not json' > "$VAULT_FILE"
log_info "Replaced the vault file with something that does not parse"

# Reset the device. It gets as far as the secrets and stops.
send_command "$APP_PORT" menu '{"itemId":"open-configuration"}'
wait_for_value "$APP_PORT" "configuration-dialog" "Reset device"
send_command "$APP_PORT" click '{"dataId":"reset-device-open"}'
wait_for_value "$APP_PORT" "reset-device-dialog" "cannot be undone"
send_command "$APP_PORT" click '{"dataId":"reset-device-continue"}'
wait_for_value "$APP_PORT" "reset-device-dialog" "Last chance"
send_command "$APP_PORT" click '{"dataId":"reset-device-confirm"}'

# The user is told, on screen, that it did not finish and that things may still be on the device.
wait_for_value "$APP_PORT" "toast-message" "The reset did not finish"
wait_for_value "$APP_PORT" "toast-message" "may still be on this device"
log_success "The failure is on screen, in a toast that does not dismiss itself"

wait_for_log "$TMP_DIR" "Device reset failed:"
log_success "The failure is in the log"

# A reset that reported failure must not also have written the success line.
if grep -q "Device reset: removed" "$TMP_DIR/app.log"; then
    log_error "The reset failed but the app also logged a completed reset"
    grep -n "Device reset" "$TMP_DIR/app.log"
    exit 1
fi
log_success "No completion was reported for the reset that failed"

# And it stopped where it broke: the app's own storage is still there, rather than half emptied by a
# reset that carried on past an error it could not handle.
if [ ! -f "$TMP_DIR/config/databases.toml" ]; then
    log_error "The reset failed at the vault but went on to empty the app's config directory anyway"
    ls -la "$TMP_DIR/config" 2>/dev/null
    exit 1
fi
log_success "The reset stopped at the failure instead of carrying on"

# The reset's own error is expected here; anything else in the log is not.
check_no_errors "$TMP_DIR" "Device reset failed:|vault"

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 39 passed: reset-device-failure"
