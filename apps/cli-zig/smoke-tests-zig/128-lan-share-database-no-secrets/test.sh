#!/bin/bash
DESCRIPTION="Share a database with no linked secrets over LAN"

# A database entry that names no S3 credentials and no encryption key arrives with nothing added to
# the receiver's vault.

# The runner exports NODE_ENV=testing, which the LAN share tests never ran under.
unset NODE_ENV

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# Also sets the exit trap that stops every process this test starts.
source "$SCRIPT_DIR/../lib/lan-share.sh"

log_info "--- Test: Share a database with no linked secrets ---"
mkdir -p "$SENDER_VAULT_DIR"

PHOTOSPHERE_CONFIG_DIR="$SENDER_CONFIG_DIR" seed_databases_config \
    '[{"name":"plain-db","description":"No secrets attached","path":"/tmp/plain-db"}]'

test_code="$(allocate_pairing_code)"
receiver_log="${TEST_TMP_DIR}/receiver-no-secrets.log"
start_receiver_with_code "dbs" "$receiver_log" "$test_code"

sender_log="${TEST_TMP_DIR}/sender-no-secrets.log"
run_cli_tracked "$sender_log" env \
    PHOTOSPHERE_VAULT_DIR="$SENDER_VAULT_DIR" \
    PHOTOSPHERE_CONFIG_DIR="$SENDER_CONFIG_DIR" \
    $SENDER_CLI_CMD dbs send --name plain-db --yes --code "$test_code" || true

if grep -q "sent successfully" "$sender_log" 2>/dev/null; then
    log_success "No-secrets DB share: sender reports success"
else
    cat "$sender_log" 2>/dev/null || true
    test_failed "No-secrets DB share: sender did not report success"
fi

wait_for_receiver_exit

receiver_secrets=$(count_vault_secrets "$RECEIVER_VAULT_DIR")
if [ "$receiver_secrets" -eq 0 ]; then
    log_success "No-secrets DB share: receiver vault is empty (no secrets to import)"
else
    test_failed "No-secrets DB share: receiver vault should be empty but has $receiver_secrets file(s)"
fi

if [ -f "${RECEIVER_CONFIG_DIR}/databases.toml" ] && grep -q "plain-db" "${RECEIVER_CONFIG_DIR}/databases.toml"; then
    log_success "No-secrets DB share: receiver has database entry"
else
    test_failed "No-secrets DB share: receiver databases.toml missing expected entry"
fi

test_passed
