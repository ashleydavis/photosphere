#!/bin/bash
DESCRIPTION="A rogue process cannot send to a receiver without its pairing code"

# A process that learns the receiver's port from its UDP broadcast posts a payload with the wrong code
# hash over HTTPS, then over plain HTTP. The first must be refused with 403, the second must not get a
# response at all, and the receiver's vault must stay empty.

# The runner exports NODE_ENV=testing, which the LAN share tests never ran under.
unset NODE_ENV

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# Also sets the exit trap that stops every process this test starts.
source "$SCRIPT_DIR/../lib/lan-share.sh"

log_info "--- Test: Rogue process cannot access receiver without pin ---"

PHOTOSPHERE_VAULT_DIR="$SENDER_VAULT_DIR" seed_vault_secret "roguekey" "api-key" \
    'ROGUE_SECRET_VALUE_12345'

receiver_code="$(allocate_pairing_code)"
receiver_log="${TEST_TMP_DIR}/receiver-rogue.log"
start_receiver_with_code "secrets" "$receiver_log" "$receiver_code"
log_info "Rogue test: receiver started"

# Matched on this receiver's own code hash, so a receiver belonging to another suite broadcasting on
# the same segment is ignored rather than attacked. See lib/udp-listen.ts.
receiver_code_hash=$(echo -n "$receiver_code" | sha256sum | cut -d' ' -f1)

broadcast_msg=$(capture_receiver_broadcast "$receiver_code_hash" "${TEST_TMP_DIR}/broadcast-rogue.log")

if [ -z "$broadcast_msg" ]; then
    test_failed "Rogue test: could not capture UDP broadcast"
fi

log_info "Rogue test: captured broadcast: $broadcast_msg"

# Parse "PSIE_RECV:{port}:{codeHash}:{fingerprint}" with bash parameter expansion. Only the port is
# needed here, and it is the first field.
without_prefix="${broadcast_msg#PSIE_RECV:}"
receiver_port="${without_prefix%%:*}"

if [ -z "$receiver_port" ]; then
    test_failed "Rogue test: could not parse port from broadcast"
fi

log_info "Rogue test: receiver is on port $receiver_port"

# Attack 1: Wrong code hash via HTTPS.
rogue_code_hash=$(echo -n "9999" | sha256sum | cut -d' ' -f1)
rogue_body="{\"codeHash\":\"${rogue_code_hash}\",\"payload\":{\"type\":\"secret\",\"secretType\":\"api-key\",\"value\":\"{\\\"label\\\":\\\"evil\\\",\\\"apiKey\\\":\\\"EVIL\\\"}\"}}"

rogue_status=$(curl -s -o /dev/null -w "%{http_code}" -k --max-time 3 \
    -X POST -H "Content-Type: application/json" -d "$rogue_body" \
    "https://127.0.0.1:${receiver_port}/share-payload" 2>/dev/null) || true

if [ "$rogue_status" = "403" ]; then
    log_success "Rogue test: HTTPS with wrong pin rejected (403)"
else
    test_failed "Rogue test: expected 403 but got $rogue_status"
fi

# Attack 2: Plain HTTP (no TLS).
http_result=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 \
    -X POST -H "Content-Type: application/json" -d "$rogue_body" \
    "http://127.0.0.1:${receiver_port}/share-payload" 2>/dev/null) || true

if [ -z "$http_result" ] || [ "$http_result" = "000" ]; then
    log_success "Rogue test: plain HTTP connection refused (server is HTTPS-only)"
else
    test_failed "Rogue test: plain HTTP got response $http_result (should have been refused)"
fi

# Verify receiver vault is still empty.
receiver_secrets=$(count_vault_secrets "$RECEIVER_VAULT_DIR")
if [ "$receiver_secrets" -eq 0 ]; then
    log_success "Rogue test: receiver vault still empty (rogue payload not accepted)"
else
    test_failed "Rogue test: receiver vault has $receiver_secrets file(s), rogue payload was accepted!"
fi

test_passed
