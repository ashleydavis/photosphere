#!/bin/bash
DESCRIPTION="A sender using the wrong pairing code is rejected and nothing is imported"

# A sender ignores any receiver whose pairing code does not match its own, so this test waits out the
# sender's discovery window before the sender gives up and reports the rejection.

# The runner exports NODE_ENV=testing, which the LAN share tests never ran under.
unset NODE_ENV

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# Also sets the exit trap that stops every process this test starts.
source "$SCRIPT_DIR/../lib/lan-share.sh"

log_info "--- Test: Wrong pairing code is rejected ---"

PHOTOSPHERE_VAULT_DIR="$SENDER_VAULT_DIR" seed_vault_secret "apikey01" "api-key" \
    'AIzaFakeKey123'

receiver_code="$(allocate_pairing_code)"
wrong_code="$(allocate_different_pairing_code "$receiver_code")"
log_info "Receiver code: $receiver_code, sender will use wrong code: $wrong_code"

receiver_log="${TEST_TMP_DIR}/receiver-wrong-code.log"
start_receiver_with_code "secrets" "$receiver_log" "$receiver_code"

sender_log="${TEST_TMP_DIR}/sender-wrong-code.log"
run_cli_tracked "$sender_log" env \
    PHOTOSPHERE_VAULT_DIR="$SENDER_VAULT_DIR" \
    PHOTOSPHERE_CONFIG_DIR="$SENDER_CONFIG_DIR" \
    $SENDER_CLI_CMD secrets send --name "apikey01" --yes --code "$wrong_code" --timeout 5 || true

if grep -q "Pairing code rejected" "$sender_log" 2>/dev/null; then
    log_success "Wrong code: sender reports rejection"
else
    cat "$sender_log" 2>/dev/null || true
    test_failed "Wrong code: sender did not report rejection"
fi

receiver_secrets=$(count_vault_secrets "$RECEIVER_VAULT_DIR")
if [ "$receiver_secrets" -eq 0 ]; then
    log_success "Wrong code: receiver vault is still empty (no import)"
else
    test_failed "Wrong code: receiver vault should be empty but has $receiver_secrets file(s)"
fi

test_passed
