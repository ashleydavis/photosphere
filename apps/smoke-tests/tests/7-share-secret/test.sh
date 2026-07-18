#!/bin/bash

# Shares a secret over LAN. Electron runs the full two-app sender+receiver round-trip
# (marked .sequential). Mobile drives the sender side only (single emulator/simulator)
# and asserts a pairing code appears.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 7 "share-secret"

TMP_DIR="$TEST_DIR/tmp"

if [ "$PLATFORM" = "electron" ]; then
    cleanup() {
        stop_app "${SENDER_PORT:-}" "$TMP_DIR/sender" 2>/dev/null || true
        stop_app "${RECEIVER_PORT:-}" "$TMP_DIR/receiver" 2>/dev/null || true
    }
    trap cleanup EXIT

    mkdir -p "$TMP_DIR/sender/vault" "$TMP_DIR/sender/config" "$TMP_DIR/receiver/vault" "$TMP_DIR/receiver/config"

    # Seed sender vault with a test secret
    cat > "$TMP_DIR/sender/vault/test-secret.json" << 'EOF'
{"name":"test-secret","type":"api-key","value":"TESTAPIKEY123"}
EOF

    start_app "$TMP_DIR/sender" 0
    SENDER_PORT="$APP_PORT"
    wait_for_ready "$SENDER_PORT"

    send_command "$SENDER_PORT" navigate '{"page":"secrets"}' || exit 1
    wait_for_log "$TMP_DIR/sender" "Secrets page loaded"

    send_command "$SENDER_PORT" click '{"dataId":"share-secret-button"}' || exit 1
    send_command "$SENDER_PORT" click '{"dataId":"share-secret-send-button"}' || exit 1

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

    send_command "$RECEIVER_PORT" navigate '{"page":"secrets"}' || exit 1
    wait_for_log "$TMP_DIR/receiver" "Secrets page loaded"

    send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-button"}' || exit 1
    wait_for_log "$TMP_DIR/receiver" "Receive secret dialog opened"

    send_command "$RECEIVER_PORT" type "{\"dataId\":\"receive-secret-code-input\",\"text\":\"$code\"}" || exit 1
    send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-start-button"}' || exit 1
    wait_for_log "$TMP_DIR/receiver" "Secret review step"

    send_command "$RECEIVER_PORT" click '{"dataId":"receive-secret-save-button"}' || exit 1
    wait_for_log "$TMP_DIR/receiver" "Secret saved"

    # After import completes the list behind the success dialog must already reflect the new secret.
    log_info "Waiting for receiver row to appear after import (before closing dialog)..."
    row_text=""
    elapsed=0
    while [ "$elapsed" -lt 10 ]; do
        response=$(curl -sf "http://localhost:$RECEIVER_PORT/get-value?dataId=secret-row-name-test-secret" 2>/dev/null || true)
        row_text=$(echo "$response" | sed 's/.*"value":"\([^"]*\)".*/\1/')
        if [ "$row_text" = "test-secret" ]; then
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if [ "$row_text" != "test-secret" ]; then
        log_error "Expected receiver Manage Secrets row 'test-secret' to appear in the DOM after import, but it did not (still empty after 10s with the success dialog still open)"
        exit 1
    fi

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

    log_success "Test 7 passed: share-secret"
else
    trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

    start_app "$TMP_DIR"
    wait_for_ready "$APP_PORT"

    send_command "$APP_PORT" reset-config '{}' || exit 1

    send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
    wait_for_log "$TMP_DIR" "Secrets page loaded"

    send_command "$APP_PORT" click '{"dataId":"add-secret-button"}' || exit 1
    wait_for_log "$TMP_DIR" "Add secret dialog opened"

    send_command "$APP_PORT" type '{"dataId":"secret-name-input","text":"smoke-secret"}' || exit 1
    send_command "$APP_PORT" click '{"dataId":"add-secret-confirm"}' || exit 1
    wait_for_log "$TMP_DIR" "Secret added"

    send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
    send_command "$APP_PORT" click '{"dataId":"share-secret-button"}' || exit 1
    send_command "$APP_PORT" click '{"dataId":"share-secret-send-button"}' || exit 1

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
        log_error "Failed to read pairing code from sender (LAN secret sharing not working on mobile)"
        exit 1
    fi
    log_info "Pairing code: $code"

    check_no_errors "$TMP_DIR"

    log_success "Test 7 passed: share-secret (sender side)"
fi
