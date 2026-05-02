#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"

source "$TEST_DIR/../lib/common.sh"

print_test_header 7 "share-secret"

TMP_DIR="$TEST_DIR/tmp"
SENDER_PORT=$(find_free_port)
RECEIVER_PORT=$(find_free_port)

cleanup() {
    if [ -f "$TMP_DIR/sender/app.pid" ]; then
        local pid
        pid=$(cat "$TMP_DIR/sender/app.pid")
        kill "$pid" 2>/dev/null || true
        sleep 0.5
        kill -9 "$pid" 2>/dev/null || true
    fi
    if [ -f "$TMP_DIR/receiver/app.pid" ]; then
        local pid
        pid=$(cat "$TMP_DIR/receiver/app.pid")
        kill "$pid" 2>/dev/null || true
        sleep 0.5
        kill -9 "$pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

mkdir -p "$TMP_DIR/sender/vault" "$TMP_DIR/sender/config" "$TMP_DIR/receiver/vault" "$TMP_DIR/receiver/config"

# Seed sender vault with a test secret
cat > "$TMP_DIR/sender/vault/test-secret.json" << 'EOF'
{"name":"test-secret","type":"api-key","value":"{\"label\":\"test-secret\",\"apiKey\":\"TESTAPIKEY123\"}"}
EOF

# Start sender app
start_app "$SENDER_PORT" "$TMP_DIR/sender" 0
wait_for_ready "$SENDER_PORT"

send_command "$SENDER_PORT" navigate '{"page":"secrets"}'
wait_for_log "$TMP_DIR/sender" "Secrets page loaded"

send_command "$SENDER_PORT" click '{"dataId":"share-secret-button"}'
send_command "$SENDER_PORT" click '{"dataId":"share-secret-send-button"}'

# Wait for pairing code element to be populated, then read it
log_info "Waiting for pairing code..."
code=""
elapsed=0
while [ "$elapsed" -lt 30 ]; do
    response=$(curl -sf "http://localhost:$SENDER_PORT/get-value?dataId=share-pairing-code" 2>/dev/null || true)
    code=$(echo "$response" | sed 's/.*"value":"\([^"]*\)".*/\1/')
    if [ -n "$code" ] && echo "$code" | grep -qE '^[0-9]{4}$'; then
        break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done

if [ -z "$code" ] || ! echo "$code" | grep -qE '^[0-9]{4}$'; then
    log_error "Failed to read pairing code from sender"
    exit 1
fi
log_info "Pairing code: $code"

# Start receiver app
start_app "$RECEIVER_PORT" "$TMP_DIR/receiver" 960
wait_for_ready "$RECEIVER_PORT"

send_command "$RECEIVER_PORT" navigate '{"page":"secrets"}'
wait_for_log "$TMP_DIR/receiver" "Secrets page loaded"

send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-button"}'
wait_for_log "$TMP_DIR/receiver" "Receive secret dialog opened"

send_command "$RECEIVER_PORT" type "{\"dataId\":\"receive-secret-code-input\",\"text\":\"$code\"}"
send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-start-button"}'
wait_for_log "$TMP_DIR/receiver" "Secret review step" 120

send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-save-button"}'
wait_for_log "$TMP_DIR/receiver" "Secret saved"

# Assert receiver vault contains the secret
if [ ! -f "$TMP_DIR/receiver/vault/test-secret.json" ]; then
    log_error "Expected $TMP_DIR/receiver/vault/test-secret.json to exist"
    exit 1
fi

if ! grep -q 'test-secret' "$TMP_DIR/receiver/vault/test-secret.json"; then
    log_error "Receiver secret file does not contain expected name"
    exit 1
fi

check_no_errors "$TMP_DIR/sender"
check_no_errors "$TMP_DIR/receiver"

stop_app "$SENDER_PORT" "$TMP_DIR/sender"
stop_app "$RECEIVER_PORT" "$TMP_DIR/receiver"

log_success "Test 7 passed: share-secret"
