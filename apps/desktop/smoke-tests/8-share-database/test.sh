#!/bin/bash

TEST_DIR="$(cd "$(dirname "$0")" && native_pwd)"
DESKTOP_DIR="$(cd "$TEST_DIR/../.." && native_pwd)"

source "$TEST_DIR/../lib/common.sh"

print_test_header 8 "share-database"

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

# Seed sender vault with S3 credentials
cat > "$TMP_DIR/sender/vault/test-s3-key.json" << 'EOF'
{"name":"test-s3-key","type":"s3-credentials","value":"{\"label\":\"test-s3-key\",\"region\":\"us-east-1\",\"accessKeyId\":\"AKIATEST\",\"secretAccessKey\":\"testsecret\"}"}
EOF

# Seed sender vault with encryption key
cat > "$TMP_DIR/sender/vault/test-enc-key.json" << 'EOF'
{"name":"test-enc-key","type":"encryption-key","value":"{\"label\":\"test-enc-key\",\"privateKeyPem\":\"test-private\",\"publicKeyPem\":\"test-public\"}"}
EOF

# Seed sender databases config (TOML format)
cat > "$TMP_DIR/sender/config/databases.toml" << 'EOF'
[[databases]]
name = "test-db"
description = ""
path = "/tmp/smoke-test-db"
s3_key = "test-s3-key"
encryption_key = "test-enc-key"

[recent_database_paths]
EOF

# Start sender app
start_app "$SENDER_PORT" "$TMP_DIR/sender" 0
wait_for_ready "$SENDER_PORT"

send_command "$SENDER_PORT" navigate '{"page":"databases"}'
wait_for_log "$TMP_DIR/sender" "Databases page loaded"

send_command "$SENDER_PORT" click '{"dataId":"share-database-button"}'
send_command "$SENDER_PORT" click '{"dataId":"share-database-send-button"}'

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

send_command "$RECEIVER_PORT" navigate '{"page":"databases"}'
wait_for_log "$TMP_DIR/receiver" "Databases page loaded"

send_command "$RECEIVER_PORT" click '{"dataId":"receive-database-button"}'
wait_for_log "$TMP_DIR/receiver" "Receive database dialog opened"

send_command "$RECEIVER_PORT" type "{\"dataId\":\"receive-database-code-input\",\"text\":\"$code\"}"
send_command "$RECEIVER_PORT" click '{"dataId":"receive-database-start-button"}'
wait_for_log "$TMP_DIR/receiver" "Database review step" 120

send_command "$RECEIVER_PORT" click '{"dataId":"receive-database-save-button"}'
wait_for_log "$TMP_DIR/receiver" "Database imported"

# Assert receiver databases config contains the database entry
if [ ! -f "$TMP_DIR/receiver/config/databases.toml" ]; then
    log_error "Expected $TMP_DIR/receiver/config/databases.toml to exist"
    exit 1
fi

if ! grep -q 'test-db' "$TMP_DIR/receiver/config/databases.toml"; then
    log_error "Receiver databases.toml does not contain expected database name"
    exit 1
fi

# Assert receiver vault has the S3 credentials
if [ ! -f "$TMP_DIR/receiver/vault/test-s3-key.json" ]; then
    log_error "Expected $TMP_DIR/receiver/vault/test-s3-key.json to exist"
    exit 1
fi

if ! grep -q 'test-s3-key' "$TMP_DIR/receiver/vault/test-s3-key.json"; then
    log_error "Receiver vault test-s3-key.json does not contain expected name"
    exit 1
fi

# Assert receiver vault has the encryption key
if [ ! -f "$TMP_DIR/receiver/vault/test-enc-key.json" ]; then
    log_error "Expected $TMP_DIR/receiver/vault/test-enc-key.json to exist"
    exit 1
fi

if ! grep -q 'test-enc-key' "$TMP_DIR/receiver/vault/test-enc-key.json"; then
    log_error "Receiver vault test-enc-key.json does not contain expected name"
    exit 1
fi

check_no_errors "$TMP_DIR/sender"
check_no_errors "$TMP_DIR/receiver"

stop_app "$SENDER_PORT" "$TMP_DIR/sender"
stop_app "$RECEIVER_PORT" "$TMP_DIR/receiver"

log_success "Test 8 passed: share-database"
