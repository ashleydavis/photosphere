#!/bin/bash

# Shares a database over LAN. Electron runs the full two-app sender+receiver round-trip
# (marked .sequential), including vault/config file asserts on the receiver. Mobile drives
# the sender side only and asserts a pairing code appears.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 8 "share-database"

TMP_DIR="$TEST_DIR/tmp"
DB_NAME="test-db"

if [ "$PLATFORM" = "electron" ]; then
    cleanup() {
        stop_app "${SENDER_PORT:-}" "$TMP_DIR/sender" 2>/dev/null || true
        stop_app "${RECEIVER_PORT:-}" "$TMP_DIR/receiver" 2>/dev/null || true
    }
    trap cleanup EXIT

    mkdir -p "$TMP_DIR/sender/vault" "$TMP_DIR/sender/config" "$TMP_DIR/receiver/vault" "$TMP_DIR/receiver/config"

    # Seed sender vault with S3 credentials
    cat > "$TMP_DIR/sender/vault/test-s3-key.json" << 'EOF'
{"name":"test-s3-key","type":"s3-credentials","value":"{\"region\":\"us-east-1\",\"accessKeyId\":\"AKIATEST\",\"secretAccessKey\":\"testsecret\"}"}
EOF

    # Seed sender vault with encryption key (raw PEM — receiver derives the public key)
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP_DIR/sender/test-enc-key.pem" 2>/dev/null
    export TEST_ENC_PEM_PATH="$TMP_DIR/sender/test-enc-key.pem"
    python3 -c "
import json, os
with open(os.environ['TEST_ENC_PEM_PATH']) as f:
    pem = f.read()
secret = {'name': 'test-enc-key', 'type': 'encryption-key', 'value': pem}
with open('$TMP_DIR/sender/vault/test-enc-key.json', 'w') as f:
    json.dump(secret, f)
"

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

    start_app "$TMP_DIR/sender" 0
    SENDER_PORT="$APP_PORT"
    wait_for_ready "$SENDER_PORT"

    send_command "$SENDER_PORT" navigate '{"page":"databases"}' || exit 1
    wait_for_log "$TMP_DIR/sender" "Databases page loaded"

    send_command "$SENDER_PORT" click '{"dataId":"share-database-button"}' || exit 1
    send_command "$SENDER_PORT" click '{"dataId":"share-database-send-button"}' || exit 1

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

    start_app "$TMP_DIR/receiver" 960
    RECEIVER_PORT="$APP_PORT"
    wait_for_ready "$RECEIVER_PORT"

    send_command "$RECEIVER_PORT" navigate '{"page":"databases"}' || exit 1
    wait_for_log "$TMP_DIR/receiver" "Databases page loaded"

    send_command "$RECEIVER_PORT" click '{"dataId":"receive-database-button"}' || exit 1
    wait_for_log "$TMP_DIR/receiver" "Receive database dialog opened"

    send_command "$RECEIVER_PORT" type "{\"dataId\":\"receive-database-code-input\",\"text\":\"$code\"}" || exit 1
    send_command "$RECEIVER_PORT" click '{"dataId":"receive-database-start-button"}' || exit 1
    wait_for_log "$TMP_DIR/receiver" "Database review step"

    send_command "$RECEIVER_PORT" click '{"dataId":"receive-database-save-button"}' || exit 1
    wait_for_log "$TMP_DIR/receiver" "Database imported"

    log_info "Waiting for receiver row to appear after import (before closing dialog)..."
    row_text=""
    elapsed=0
    while [ "$elapsed" -lt 10 ]; do
        response=$(curl -sf "http://localhost:$RECEIVER_PORT/get-value?dataId=database-row-name-test-db" 2>/dev/null || true)
        row_text=$(echo "$response" | sed 's/.*"value":"\([^"]*\)".*/\1/')
        if [ "$row_text" = "test-db" ]; then
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if [ "$row_text" != "test-db" ]; then
        log_error "Expected receiver Manage Databases row 'test-db' to appear in the DOM after import, but it did not (still empty after 10s with the success dialog still open)"
        exit 1
    fi

    if [ ! -f "$TMP_DIR/receiver/config/databases.toml" ]; then
        log_error "Expected $TMP_DIR/receiver/config/databases.toml to exist"
        exit 1
    fi

    if ! grep -q 'test-db' "$TMP_DIR/receiver/config/databases.toml"; then
        log_error "Receiver databases.toml does not contain expected database name"
        exit 1
    fi

    if [ ! -f "$TMP_DIR/receiver/vault/test-s3-key.json" ]; then
        log_error "Expected $TMP_DIR/receiver/vault/test-s3-key.json to exist"
        exit 1
    fi

    if ! grep -q 'test-s3-key' "$TMP_DIR/receiver/vault/test-s3-key.json"; then
        log_error "Receiver vault test-s3-key.json does not contain expected name"
        exit 1
    fi

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

    log_success "Test 8 passed: share-database"
else
    trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

    start_app "$TMP_DIR"
    wait_for_ready "$APP_PORT"

    send_command "$APP_PORT" reset-config '{}' || exit 1
    create_database "$TMP_DIR/$DB_NAME"
    seed_database "$TMP_DIR/$DB_NAME" "$DB_NAME"

    send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
    wait_for_log "$TMP_DIR" "Databases page loaded"

    send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
    send_command "$APP_PORT" click '{"dataId":"add-database-button"}' || exit 1
    wait_for_log "$TMP_DIR" "Add database dialog opened"

    send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"My Test DB"}' || exit 1
    send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$DB_NAME\"}" || exit 1
    send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}' || exit 1
    wait_for_log "$TMP_DIR" "Database entry added"

    send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
    wait_for_log "$TMP_DIR" "Databases page loaded"

    send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
    send_command "$APP_PORT" click '{"dataId":"share-database-button"}' || exit 1
    send_command "$APP_PORT" click '{"dataId":"share-database-send-button"}' || exit 1

    log_info "Waiting for pairing code..."
    code=""
    elapsed=0
    while [ "$elapsed" -lt 20 ]; do
        response=$(curl -sf "http://localhost:$APP_PORT/get-value?dataId=share-pairing-code" 2>/dev/null || true)
        code=$(echo "$response" | sed 's/.*"value":"\([^"]*\)".*/\1/')
        if [ -n "$code" ] && echo "$code" | grep -qE '^[0-9]{4}$'; then
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if [ -z "$code" ] || ! echo "$code" | grep -qE '^[0-9]{4}$'; then
        log_error "Failed to read pairing code from sender (LAN database sharing not working on mobile)"
        exit 1
    fi
    log_info "Pairing code: $code"

    check_no_errors "$TMP_DIR"

    log_success "Test 8 passed: share-database (sender side)"
fi
