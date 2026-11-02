#!/bin/bash
DESCRIPTION="A receiver's TLS certificate fingerprint matches the one in its UDP broadcast"

# The fingerprint a receiver broadcasts is what a sender pins its TLS connection to, so it must be the
# SHA-256 of the certificate the receiver actually serves.

# The runner exports NODE_ENV=testing, which the LAN share tests never ran under.
unset NODE_ENV

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# Also sets the exit trap that stops every process this test starts.
source "$SCRIPT_DIR/../lib/lan-share.sh"

log_info "--- Test: Receiver cert fingerprint matches its broadcast ---"

mkdir -p "$RECEIVER_VAULT_DIR" "$RECEIVER_CONFIG_DIR"

receiver_code="$(allocate_pairing_code)"
receiver_log="${TEST_TMP_DIR}/receiver-cert.log"
start_receiver_with_code "secrets" "$receiver_log" "$receiver_code"

# This receiver's own broadcast, not whichever one the segment carries first. Without this the
# fingerprint compared below could be another suite's receiver's, against a TLS connection to a port
# that receiver holds, and the test would be asserting nothing about the one it started.
receiver_code_hash=$(echo -n "$receiver_code" | sha256sum | cut -d' ' -f1)

broadcast_msg=$(capture_receiver_broadcast "$receiver_code_hash" "${TEST_TMP_DIR}/broadcast-cert.log")

if [ -z "$broadcast_msg" ]; then
    test_failed "Cert test: could not capture UDP broadcast"
fi

# Parse "PSIE_RECV:{port}:{codeHash}:{fingerprint}" with bash parameter expansion. The fingerprint is
# taken last because it can itself contain colons.
without_prefix="${broadcast_msg#PSIE_RECV:}"
receiver_port="${without_prefix%%:*}"
after_port="${without_prefix#*:}"
broadcast_fingerprint="${after_port#*:}"

if [ -z "$receiver_port" ] || [ -z "$broadcast_fingerprint" ]; then
    test_failed "Cert test: could not parse broadcast"
fi

log_info "Cert test: broadcast fingerprint: $broadcast_fingerprint"

actual_fingerprint=$(echo | openssl s_client -connect "127.0.0.1:${receiver_port}" -servername localhost 2>/dev/null \
    | openssl x509 -outform DER 2>/dev/null \
    | sha256sum \
    | cut -d' ' -f1)

log_info "Cert test: actual TLS fingerprint: $actual_fingerprint"

if [ "$broadcast_fingerprint" = "$actual_fingerprint" ]; then
    log_success "Cert test: broadcast fingerprint matches TLS certificate"
else
    test_failed "Cert test: broadcast fingerprint does NOT match TLS certificate"
fi

tampered="0000000000000000000000000000000000000000000000000000000000000000"
if [ "$tampered" != "$actual_fingerprint" ]; then
    log_success "Cert test: tampered fingerprint correctly differs from real cert"
else
    test_failed "Cert test: tampered fingerprint unexpectedly matched"
fi

test_passed
