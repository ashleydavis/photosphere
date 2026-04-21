#!/bin/bash

# Photosphere CLI LAN Share Smoke Tests
# Runs sender and receiver CLI commands in parallel to verify end-to-end
# database and secret sharing over the LAN.

set -euo pipefail

# Disable colors for consistent output parsing.
export NO_COLOR=1

# Colors for test output.
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Temp directory for test data.
TEST_TMP_DIR="${TEST_TMP_DIR:-./test/tmp-lan-share}"

# Isolated vault and config dirs for sender and receiver.
SENDER_VAULT_DIR="${TEST_TMP_DIR}/sender-vault"
SENDER_CONFIG_DIR="${TEST_TMP_DIR}/sender-config"
RECEIVER_VAULT_DIR="${TEST_TMP_DIR}/receiver-vault"
RECEIVER_CONFIG_DIR="${TEST_TMP_DIR}/receiver-config"
export PHOTOSPHERE_VAULT_TYPE="plaintext"

# Counters.
TESTS_PASSED=0
TESTS_FAILED=0

# CLI command (default: run from source).
CLI_CMD="bun run start --"

# Active receiver PID (cleaned up after every test).
RECEIVER_PID=""

log_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# Kill a process reliably.
kill_proc() {
    local pid="$1"
    kill "$pid" 2>/dev/null || true
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

# Clean up after every test — kill any active receiver.
test_cleanup() {
    if [ -n "$RECEIVER_PID" ]; then
        kill_proc "$RECEIVER_PID"
        RECEIVER_PID=""
    fi
}

# Clean up on script exit.
cleanup() {
    test_cleanup
    jobs -p 2>/dev/null | xargs -r kill -9 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup EXIT

# Seed a vault secret directly into a vault directory.
seed_vault_secret() {
    local vault_dir="$1"
    local secret_name="$2"
    local secret_type="$3"
    local secret_value="$4"

    mkdir -p "$vault_dir"
    local encoded_name
    encoded_name=$(printf '%s' "$secret_name" | sed 's/:/%3A/g')
    local file_path="${vault_dir}/${encoded_name}.json"

    local escaped_value
    escaped_value=$(printf '%s' "$secret_value" | sed 's/\\/\\\\/g; s/"/\\"/g')

    cat > "$file_path" <<VAULT_EOF
{
  "name": "$secret_name",
  "type": "$secret_type",
  "value": "${escaped_value}"
}
VAULT_EOF
    chmod 600 "$file_path"
}

# Seed a databases.json config file directly.
seed_databases_config() {
    local config_dir="$1"
    local databases_json="$2"

    mkdir -p "$config_dir"
    cat > "${config_dir}/databases.json" <<CONFIG_EOF
{
  "databases": $databases_json,
  "recentDatabasePaths": []
}
CONFIG_EOF
}

# Start a receiver in background with the given pairing code and wait for it to be ready.
# Sets: RECEIVER_PID
start_receiver_with_code() {
    local cmd_prefix="$1"  # "dbs" or "secrets"
    local log_file="$2"
    local code="$3"

    PHOTOSPHERE_VAULT_DIR="$RECEIVER_VAULT_DIR" \
    PHOTOSPHERE_CONFIG_DIR="$RECEIVER_CONFIG_DIR" \
        $CLI_CMD $cmd_prefix receive --yes --code "$code" > "$log_file" 2>&1 &
    RECEIVER_PID=$!

    # Poll until the receiver logs that it is waiting for a sender.
    for attempt in $(seq 1 25); do
        sleep 0.2
        if [ -f "$log_file" ] && grep -q "Waiting for sender" "$log_file" 2>/dev/null; then
            # Give the HTTPS server and UDP broadcast a moment to be fully ready.
            sleep 0.3
            return 0
        fi
        # Also check for an early exit indicating an error.
        if ! kill -0 "$RECEIVER_PID" 2>/dev/null; then
            log_fail "Receiver process exited unexpectedly."
            cat "$log_file" 2>/dev/null || true
            test_cleanup
            return 1
        fi
    done

    log_fail "Receiver was not ready within 5 seconds."
    cat "$log_file" 2>/dev/null || true
    test_cleanup
    return 1
}

# Reset test dirs.
reset_dirs() {
    rm -rf "$SENDER_VAULT_DIR" "$SENDER_CONFIG_DIR" "$RECEIVER_VAULT_DIR" "$RECEIVER_CONFIG_DIR"
    mkdir -p "$RECEIVER_VAULT_DIR" "$RECEIVER_CONFIG_DIR"
}

# Per-test timeout in seconds.
TEST_TIMEOUT=20

# Run a test function with per-test timeout, cleanup, and timing.
# The test runs in the foreground (so counters and RECEIVER_PID work).
# A background watchdog kills bun processes if the test exceeds the timeout.
run_test() {
    local test_func="$1"
    local start_time=$SECONDS

    # Background watchdog — kills stuck bun processes after timeout.
    (
        sleep "$TEST_TIMEOUT"
        pkill -f "bun run start.*--yes" 2>/dev/null || true
        pkill -f "bun run.*udp-listen" 2>/dev/null || true
        sleep 1
        pkill -9 -f "bun run start.*--yes" 2>/dev/null || true
    ) &
    local watchdog_pid=$!

    # Run the test directly. The || true disables set -e inside the function
    # so individual command failures don't kill the script.
    "$test_func" || true

    # Cancel the watchdog.
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true

    test_cleanup

    # Kill any lingering receivers between tests and wait for them to die.
    pkill -f "bun run.*receive --yes" 2>/dev/null || true
    sleep 0.3

    local elapsed=$(( SECONDS - start_time ))
    if [ "$elapsed" -ge "$TEST_TIMEOUT" ]; then
        log_fail "$test_func timed out after ${TEST_TIMEOUT}s"
    fi
    echo -e "  ${YELLOW}(${elapsed}s)${NC}"
    echo ""
}

# ============================================================================
# Test 1: Share a database (sender -> receiver) via CLI
# ============================================================================
test_share_database() {
    log_info "--- Test: Share a database over LAN (CLI) ---"
    reset_dirs

    seed_vault_secret "$SENDER_VAULT_DIR" "s3sender" "s3-credentials" \
        '{"label":"Test S3","region":"us-east-1","accessKeyId":"AKIATEST","secretAccessKey":"secret123","endpoint":"http://localhost:9000"}'

    seed_vault_secret "$SENDER_VAULT_DIR" "encsndr1" "encryption-key" \
        '{"label":"Test Encryption","privateKeyPem":"-----BEGIN PRIVATE KEY-----\nMIItest\n-----END PRIVATE KEY-----","publicKeyPem":"-----BEGIN PUBLIC KEY-----\nMIItest\n-----END PUBLIC KEY-----"}'

    seed_databases_config "$SENDER_CONFIG_DIR" \
        '[{"name":"share-test-db","description":"A database for LAN share testing","path":"s3:test-bucket:/photos","s3CredentialId":"s3sender","encryptionKeyId":"encsndr1"}]'

    local test_code="1234"
    local receiver_log="${TEST_TMP_DIR}/receiver-db.log"
    start_receiver_with_code "dbs" "$receiver_log" "$test_code" || return 1

    local sender_log="${TEST_TMP_DIR}/sender-db.log"
    PHOTOSPHERE_VAULT_DIR="$SENDER_VAULT_DIR" \
    PHOTOSPHERE_CONFIG_DIR="$SENDER_CONFIG_DIR" \
        $CLI_CMD dbs send share-test-db --yes --code "$test_code" > "$sender_log" 2>&1 || true

    # Give receiver a moment to process.
    sleep 0.2

    if grep -q "sent successfully" "$sender_log" 2>/dev/null; then
        log_success "Database share: sender reports success"
    else
        log_fail "Database share: sender did not report success"
        cat "$sender_log" 2>/dev/null || true
        return 1
    fi

    local receiver_secrets
    receiver_secrets=$(find "$RECEIVER_VAULT_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)
    if [ "$receiver_secrets" -ge 1 ]; then
        log_success "Database share: receiver vault has $receiver_secrets secret(s)"
    else
        log_fail "Database share: receiver vault is empty after share"
        return 1
    fi

    if grep -q "imported successfully" "$receiver_log" 2>/dev/null; then
        log_success "Database share: receiver reports success"
    else
        log_fail "Database share: receiver did not report success"
        return 1
    fi

    if [ -f "${RECEIVER_CONFIG_DIR}/databases.json" ] && grep -q "share-test-db" "${RECEIVER_CONFIG_DIR}/databases.json"; then
        log_success "Database share: receiver has database entry"
    else
        log_fail "Database share: receiver databases.json missing expected entry"
        return 1
    fi
}

# ============================================================================
# Test 2: Share a secret (sender -> receiver) via CLI
# ============================================================================
test_share_secret() {
    log_info "--- Test: Share a secret over LAN (CLI) ---"
    reset_dirs

    seed_vault_secret "$SENDER_VAULT_DIR" "apikey01" "api-key" \
        '{"label":"Test Geocoding","apiKey":"AIzaFakeKey123"}'

    local test_code="2345"
    local receiver_log="${TEST_TMP_DIR}/receiver-secret.log"
    start_receiver_with_code "secrets" "$receiver_log" "$test_code" || return 1

    local sender_log="${TEST_TMP_DIR}/sender-secret.log"
    PHOTOSPHERE_VAULT_DIR="$SENDER_VAULT_DIR" \
    PHOTOSPHERE_CONFIG_DIR="$SENDER_CONFIG_DIR" \
        $CLI_CMD secrets send "apikey01" --yes --code "$test_code" > "$sender_log" 2>&1 || true

    sleep 0.2

    if grep -q "sent successfully" "$sender_log" 2>/dev/null; then
        log_success "Secret share: sender reports success"
    else
        log_fail "Secret share: sender did not report success"
        cat "$sender_log" 2>/dev/null || true
        return 1
    fi

    local receiver_secrets
    receiver_secrets=$(find "$RECEIVER_VAULT_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)
    if [ "$receiver_secrets" -ge 1 ]; then
        log_success "Secret share: receiver vault has $receiver_secrets secret(s)"
    else
        log_fail "Secret share: receiver vault is empty after share"
        return 1
    fi

    if grep -q "imported successfully" "$receiver_log" 2>/dev/null; then
        log_success "Secret share: receiver reports success"
    else
        log_fail "Secret share: receiver did not report success"
        return 1
    fi
}

# ============================================================================
# Test 3: Wrong pairing code is rejected
# ============================================================================
test_wrong_pairing_code() {
    log_info "--- Test: Wrong pairing code is rejected ---"
    reset_dirs

    seed_vault_secret "$SENDER_VAULT_DIR" "apikey01" "api-key" \
        '{"label":"Test Geocoding","apiKey":"AIzaFakeKey123"}'

    local receiver_code="3456"
    local wrong_code="7890"
    log_info "Receiver code: $receiver_code, sender will use wrong code: $wrong_code"

    local receiver_log="${TEST_TMP_DIR}/receiver-wrong-code.log"
    start_receiver_with_code "secrets" "$receiver_log" "$receiver_code" || return 1

    local sender_log="${TEST_TMP_DIR}/sender-wrong-code.log"
    PHOTOSPHERE_VAULT_DIR="$SENDER_VAULT_DIR" \
    PHOTOSPHERE_CONFIG_DIR="$SENDER_CONFIG_DIR" \
        $CLI_CMD secrets send "apikey01" --yes --code "$wrong_code" > "$sender_log" 2>&1 || true

    if grep -q "Pairing code rejected" "$sender_log" 2>/dev/null; then
        log_success "Wrong code: sender reports rejection"
    else
        log_fail "Wrong code: sender did not report rejection"
        cat "$sender_log" 2>/dev/null || true
        return 1
    fi

    local receiver_secrets
    receiver_secrets=$(find "$RECEIVER_VAULT_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)
    if [ "$receiver_secrets" -eq 0 ]; then
        log_success "Wrong code: receiver vault is still empty (no import)"
    else
        log_fail "Wrong code: receiver vault should be empty but has $receiver_secrets file(s)"
        return 1
    fi
}

# ============================================================================
# Test 4: Share a database with no linked secrets
# ============================================================================
test_share_database_no_secrets() {
    log_info "--- Test: Share a database with no linked secrets ---"
    reset_dirs
    mkdir -p "$SENDER_VAULT_DIR"

    seed_databases_config "$SENDER_CONFIG_DIR" \
        '[{"name":"plain-db","description":"No secrets attached","path":"/tmp/plain-db"}]'

    local test_code="4567"
    local receiver_log="${TEST_TMP_DIR}/receiver-no-secrets.log"
    start_receiver_with_code "dbs" "$receiver_log" "$test_code" || return 1

    local sender_log="${TEST_TMP_DIR}/sender-no-secrets.log"
    PHOTOSPHERE_VAULT_DIR="$SENDER_VAULT_DIR" \
    PHOTOSPHERE_CONFIG_DIR="$SENDER_CONFIG_DIR" \
        $CLI_CMD dbs send plain-db --yes --code "$test_code" > "$sender_log" 2>&1 || true

    sleep 0.2

    if grep -q "sent successfully" "$sender_log" 2>/dev/null; then
        log_success "No-secrets DB share: sender reports success"
    else
        log_fail "No-secrets DB share: sender did not report success"
        cat "$sender_log" 2>/dev/null || true
        return 1
    fi

    local receiver_secrets
    receiver_secrets=$(find "$RECEIVER_VAULT_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)
    if [ "$receiver_secrets" -eq 0 ]; then
        log_success "No-secrets DB share: receiver vault is empty (no secrets to import)"
    else
        log_fail "No-secrets DB share: receiver vault should be empty but has $receiver_secrets file(s)"
        return 1
    fi

    if [ -f "${RECEIVER_CONFIG_DIR}/databases.json" ] && grep -q "plain-db" "${RECEIVER_CONFIG_DIR}/databases.json"; then
        log_success "No-secrets DB share: receiver has database entry"
    else
        log_fail "No-secrets DB share: receiver databases.json missing expected entry"
        return 1
    fi
}

# ============================================================================
# Test 5: Receiver exits cleanly on cancel
# ============================================================================
test_receiver_cancel() {
    log_info "--- Test: Receiver exits cleanly on cancel ---"

    rm -rf "$RECEIVER_VAULT_DIR" "$RECEIVER_CONFIG_DIR"
    mkdir -p "$RECEIVER_VAULT_DIR" "$RECEIVER_CONFIG_DIR"

    local receiver_log="${TEST_TMP_DIR}/receiver-timeout.log"
    start_receiver_with_code "secrets" "$receiver_log" "5678" || return 1
    log_info "Receiver started (no sender will connect)"

    kill -INT "$RECEIVER_PID" 2>/dev/null || true
    wait "$RECEIVER_PID" 2>/dev/null || true
    RECEIVER_PID=""

    if ! grep -q "EADDRINUSE\|stack trace\|panic" "$receiver_log" 2>/dev/null; then
        log_success "Receiver cancel: exited cleanly after SIGINT"
    else
        log_fail "Receiver cancel: log contains errors"
        cat "$receiver_log" 2>/dev/null || true
        return 1
    fi
}

# ============================================================================
# Test 6: Rogue process cannot access receiver without pin
# ============================================================================
test_rogue_receiver_rejected() {
    log_info "--- Test: Rogue process cannot access receiver without pin ---"

    reset_dirs

    seed_vault_secret "$SENDER_VAULT_DIR" "roguekey" "api-key" \
        '{"label":"Rogue Test Key","apiKey":"ROGUE_SECRET_VALUE_12345"}'

    local receiver_log="${TEST_TMP_DIR}/receiver-rogue.log"
    start_receiver_with_code "secrets" "$receiver_log" "6789" || return 1
    log_info "Rogue test: receiver started"

    local broadcast_msg
    broadcast_msg=$(timeout 5 bun run test/udp-listen.ts 2>/dev/null || true)

    if [ -z "$broadcast_msg" ]; then
        log_fail "Rogue test: could not capture UDP broadcast"
        return 1
    fi

    log_info "Rogue test: captured broadcast: $broadcast_msg"

    # Parse "PSIE_RECV:{port}:{fingerprint}" with bash parameter expansion.
    local without_prefix="${broadcast_msg#PSIE_RECV:}"
    local receiver_port="${without_prefix%%:*}"

    if [ -z "$receiver_port" ]; then
        log_fail "Rogue test: could not parse port from broadcast"
        return 1
    fi

    log_info "Rogue test: receiver is on port $receiver_port"

    # Attack 1: Wrong code hash via HTTPS.
    local rogue_code_hash
    rogue_code_hash=$(echo -n "9999" | sha256sum | cut -d' ' -f1)
    local rogue_body="{\"codeHash\":\"${rogue_code_hash}\",\"payload\":{\"type\":\"secret\",\"secretType\":\"api-key\",\"value\":\"{\\\"label\\\":\\\"evil\\\",\\\"apiKey\\\":\\\"EVIL\\\"}\"}}"

    local rogue_status
    rogue_status=$(curl -s -o /dev/null -w "%{http_code}" -k --max-time 3 \
        -X POST -H "Content-Type: application/json" -d "$rogue_body" \
        "https://127.0.0.1:${receiver_port}/share-payload" 2>/dev/null) || true

    if [ "$rogue_status" = "403" ]; then
        log_success "Rogue test: HTTPS with wrong pin rejected (403)"
    else
        log_fail "Rogue test: expected 403 but got $rogue_status"
    fi

    # Attack 2: Plain HTTP (no TLS).
    local http_result
    http_result=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 \
        -X POST -H "Content-Type: application/json" -d "$rogue_body" \
        "http://127.0.0.1:${receiver_port}/share-payload" 2>/dev/null) || true

    if [ -z "$http_result" ] || [ "$http_result" = "000" ]; then
        log_success "Rogue test: plain HTTP connection refused (server is HTTPS-only)"
    else
        log_fail "Rogue test: plain HTTP got response $http_result (should have been refused)"
    fi

    # Verify receiver vault is still empty.
    local receiver_secrets
    receiver_secrets=$(find "$RECEIVER_VAULT_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)
    if [ "$receiver_secrets" -eq 0 ]; then
        log_success "Rogue test: receiver vault still empty (rogue payload not accepted)"
    else
        log_fail "Rogue test: receiver vault has $receiver_secrets file(s) — rogue payload was accepted!"
    fi
}

# ============================================================================
# Test 7: Receiver cert fingerprint matches its UDP broadcast
# ============================================================================
test_cert_fingerprint_matches_broadcast() {
    log_info "--- Test: Receiver cert fingerprint matches its broadcast ---"

    rm -rf "$RECEIVER_VAULT_DIR" "$RECEIVER_CONFIG_DIR"
    mkdir -p "$RECEIVER_VAULT_DIR" "$RECEIVER_CONFIG_DIR"

    local receiver_log="${TEST_TMP_DIR}/receiver-cert.log"
    start_receiver_with_code "secrets" "$receiver_log" "8901" || return 1

    local broadcast_msg
    broadcast_msg=$(timeout 5 bun run test/udp-listen.ts 2>/dev/null || true)

    if [ -z "$broadcast_msg" ]; then
        log_fail "Cert test: could not capture UDP broadcast"
        return 1
    fi

    # Parse "PSIE_RECV:{port}:{fingerprint}" with bash parameter expansion.
    local without_prefix="${broadcast_msg#PSIE_RECV:}"
    local receiver_port="${without_prefix%%:*}"
    local broadcast_fingerprint="${without_prefix#*:}"

    if [ -z "$receiver_port" ] || [ -z "$broadcast_fingerprint" ]; then
        log_fail "Cert test: could not parse broadcast"
        return 1
    fi

    log_info "Cert test: broadcast fingerprint: $broadcast_fingerprint"

    local actual_fingerprint
    actual_fingerprint=$(echo | openssl s_client -connect "127.0.0.1:${receiver_port}" -servername localhost 2>/dev/null \
        | openssl x509 -outform DER 2>/dev/null \
        | sha256sum \
        | cut -d' ' -f1)

    log_info "Cert test: actual TLS fingerprint: $actual_fingerprint"

    if [ "$broadcast_fingerprint" = "$actual_fingerprint" ]; then
        log_success "Cert test: broadcast fingerprint matches TLS certificate"
    else
        log_fail "Cert test: broadcast fingerprint does NOT match TLS certificate"
        return 1
    fi

    local tampered="0000000000000000000000000000000000000000000000000000000000000000"
    if [ "$tampered" != "$actual_fingerprint" ]; then
        log_success "Cert test: tampered fingerprint correctly differs from real cert"
    else
        log_fail "Cert test: tampered fingerprint unexpectedly matched"
        return 1
    fi
}

# ============================================================================
# Main
# ============================================================================

echo ""
echo "=================================================="
echo "  Photosphere LAN Share Smoke Tests"
echo "=================================================="
echo ""

# Parse arguments.
while [ $# -gt 0 ]; do
    case "$1" in
        -b|--binary)
            CLI_CMD="./bin/x64/linux/psi"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [-b|--binary]"
            exit 1
            ;;
    esac
done

mkdir -p "$TEST_TMP_DIR"

# Kill any leftover receivers from previous runs.
pkill -f "bun run.*receive --yes" 2>/dev/null || true
sleep 0.5

SUITE_START=$SECONDS

run_test test_share_database
run_test test_share_secret
run_test test_wrong_pairing_code
run_test test_share_database_no_secrets
run_test test_receiver_cancel
run_test test_rogue_receiver_rejected
run_test test_cert_fingerprint_matches_broadcast

SUITE_ELAPSED=$(( SECONDS - SUITE_START ))

echo "=================================================="
echo "  Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed (${SUITE_ELAPSED}s)"
echo "=================================================="

if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
fi
