#!/bin/bash

#
# Photosphere CLI <-> Desktop LAN Share Smoke Tests
#
# Exercises end-to-end LAN sharing across the CLI and the Electron desktop app
# in both directions, for both secrets and databases:
#
#   1. CLI sender      -> Desktop receiver  (secret)
#   2. CLI sender      -> Desktop receiver  (database + linked secrets)
#   3. Desktop sender  -> CLI receiver      (secret)
#   4. Desktop sender  -> CLI receiver      (database + linked secrets)
#

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
DESKTOP_DIR="$ROOT_DIR/apps/desktop"
DESKTOP_FRONTEND_DIR="$ROOT_DIR/apps/desktop-frontend"
CLI_DIR="$ROOT_DIR/apps/cli"

# Shared helpers: start_app, wait_for_ready, wait_for_log, send_command, stop_app,
# find_free_port, log_info / log_success / log_error.
source "$DESKTOP_DIR/smoke-tests/lib/common.sh"

TMP_ROOT="$ROOT_DIR/tmp-cli-desktop-lan-share"

# Counters and bookkeeping for the suite.
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TEST_NAMES=()

# PIDs of any CLI helper processes for the current test, cleaned up between tests.
CLI_PIDS=()

# Per-test timeout (covers UDP discovery + TLS pairing + file IO).
LAN_TIMEOUT=60

#
# Kills any CLI helper processes started by the current test, ignoring missing PIDs.
#
cleanup_cli_pids() {
    local cli_pid
    for cli_pid in "${CLI_PIDS[@]+"${CLI_PIDS[@]}"}"; do
        kill "$cli_pid" 2>/dev/null || true
        sleep 0.3
        kill -9 "$cli_pid" 2>/dev/null || true
        wait "$cli_pid" 2>/dev/null || true
    done
    CLI_PIDS=()
}

#
# Global cleanup on script exit — terminates any lingering CLI receivers/senders
# and any background jobs spawned by tests.
#
suite_cleanup() {
    cleanup_cli_pids
    pkill -f "bun run.*secrets (send|receive)" 2>/dev/null || true
    pkill -f "bun run.*dbs (send|receive)" 2>/dev/null || true
    jobs -p 2>/dev/null | xargs -r kill 2>/dev/null || true
}
trap suite_cleanup EXIT

#
# Bundles the desktop app and the frontend so start_app can launch Electron from source.
#
bundle_desktop() {
    log_info "Bundling desktop-frontend..."
    (cd "$DESKTOP_FRONTEND_DIR" && bun run bundle) > "$TMP_ROOT/bundle-frontend.log" 2>&1
    log_info "Bundling desktop..."
    (cd "$DESKTOP_DIR" && bun run bundle) > "$TMP_ROOT/bundle-desktop.log" 2>&1
}

#
# Seeds a vault directory with a single plain-text secret JSON file.
# Usage: seed_secret <vault_dir> <name> <type> <value>
#
seed_secret() {
    local vault_dir="$1"
    local secret_name="$2"
    local secret_type="$3"
    local secret_value="$4"
    mkdir -p "$vault_dir"
    local escaped_value
    escaped_value=$(printf '%s' "$secret_value" | sed 's/\\/\\\\/g; s/"/\\"/g')
    cat > "$vault_dir/$secret_name.json" <<VAULT_EOF
{
  "name": "$secret_name",
  "type": "$secret_type",
  "value": "$escaped_value"
}
VAULT_EOF
    chmod 600 "$vault_dir/$secret_name.json"
}

#
# Seeds a vault directory with an RSA-2048 encryption-key secret built from a real PEM.
# Usage: seed_encryption_key <vault_dir> <name>
#
seed_encryption_key() {
    local vault_dir="$1"
    local secret_name="$2"
    mkdir -p "$vault_dir"
    local pem_file="$vault_dir/$secret_name.pem"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$pem_file" 2>/dev/null
    PEM_FILE="$pem_file" VAULT_FILE="$vault_dir/$secret_name.json" SECRET_NAME="$secret_name" python3 <<'PY'
import json
import os
with open(os.environ['PEM_FILE']) as keyFile:
    pem = keyFile.read()
secret = {"name": os.environ['SECRET_NAME'], "type": "encryption-key", "value": pem}
with open(os.environ['VAULT_FILE'], 'w') as outFile:
    json.dump(secret, outFile)
PY
    chmod 600 "$vault_dir/$secret_name.json"
    rm -f "$pem_file"
}

#
# Writes a databases.toml config with a single database entry.
# Usage: seed_databases_toml <config_dir> <db_name> <db_path> [s3_key] [encryption_key]
#
seed_databases_toml() {
    local config_dir="$1"
    local db_name="$2"
    local db_path="$3"
    local s3_key="${4:-}"
    local encryption_key="${5:-}"
    mkdir -p "$config_dir"
    {
        echo "[[databases]]"
        echo "name = \"$db_name\""
        echo "description = \"\""
        echo "path = \"$db_path\""
        if [ -n "$s3_key" ]; then
            echo "s3_key = \"$s3_key\""
        fi
        if [ -n "$encryption_key" ]; then
            echo "encryption_key = \"$encryption_key\""
        fi
        echo ""
        echo "[recent_database_paths]"
    } > "$config_dir/databases.toml"
}

#
# Writes a databases.json config (CLI-style) with a single database entry.
# Usage: seed_databases_json <config_dir> <db_name> <db_path> [s3_key] [encryption_key]
#
seed_databases_json() {
    local config_dir="$1"
    local db_name="$2"
    local db_path="$3"
    local s3_key="${4:-}"
    local encryption_key="${5:-}"
    mkdir -p "$config_dir"
    local extras=""
    if [ -n "$s3_key" ]; then
        extras+=",\"s3Key\":\"$s3_key\""
    fi
    if [ -n "$encryption_key" ]; then
        extras+=",\"encryptionKey\":\"$encryption_key\""
    fi
    cat > "$config_dir/databases.json" <<JSON_EOF
{
  "databases": [{"name":"$db_name","description":"","path":"$db_path"$extras}],
  "recentDatabasePaths": []
}
JSON_EOF
}

#
# Polls the desktop test-control server for the pairing-code element and prints
# it once it contains a 4-digit value. Returns non-zero on timeout.
# Usage: read_desktop_pairing_code <port>
#
read_desktop_pairing_code() {
    local port="$1"
    local elapsed=0
    while [ "$elapsed" -lt 30 ]; do
        local response
        response=$(curl -sf "http://localhost:$port/get-value?dataId=share-pairing-code" 2>/dev/null || true)
        local code
        code=$(echo "$response" | sed 's/.*"value":"\([^"]*\)".*/\1/')
        if [ -n "$code" ] && echo "$code" | grep -qE '^[0-9]{4}$'; then
            echo "$code"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

#
# Starts a CLI receiver in the background and records its PID for later cleanup.
# Returns once the receiver is ready (broadcasting) or has already completed.
# Usage: start_cli_receiver <subcommand> <vault_dir> <config_dir> <log_file> <code>
#   subcommand is "secrets" or "dbs".
#
start_cli_receiver() {
    local subcommand="$1"
    local vault_dir="$2"
    local config_dir="$3"
    local log_file="$4"
    local code="$5"
    (
        cd "$CLI_DIR"
        PHOTOSPHERE_VAULT_DIR="$vault_dir" \
        PHOTOSPHERE_CONFIG_DIR="$config_dir" \
        PHOTOSPHERE_VAULT_TYPE=plaintext \
            bun run start -- "$subcommand" receive --yes --code "$code"
    ) > "$log_file" 2>&1 &
    local cli_pid=$!
    CLI_PIDS+=("$cli_pid")
    local elapsed=0
    while [ "$elapsed" -lt 15 ]; do
        if grep -q "Waiting for sender\|imported successfully\|Pairing code rejected" "$log_file" 2>/dev/null; then
            return 0
        fi
        if ! kill -0 "$cli_pid" 2>/dev/null; then
            return 0
        fi
        sleep 0.5
        elapsed=$((elapsed + 1))
    done
    log_error "CLI receiver did not start within timeout. Log:"
    cat "$log_file" 2>/dev/null || true
    return 1
}

#
# Runs a CLI sender to completion in the foreground.
# Usage: run_cli_sender <subcommand> <vault_dir> <config_dir> <log_file> <code> <name>
#   subcommand is "secrets" or "dbs", name is the secret or database name to send.
#
run_cli_sender() {
    local subcommand="$1"
    local vault_dir="$2"
    local config_dir="$3"
    local log_file="$4"
    local code="$5"
    local name="$6"
    (
        cd "$CLI_DIR"
        PHOTOSPHERE_VAULT_DIR="$vault_dir" \
        PHOTOSPHERE_CONFIG_DIR="$config_dir" \
        PHOTOSPHERE_VAULT_TYPE=plaintext \
            bun run start -- "$subcommand" send --name "$name" --yes --code "$code"
    ) > "$log_file" 2>&1
}

#
# Marks the current test as passed and prints a green banner.
#
mark_pass() {
    log_success "$1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

#
# Marks the current test as failed, dumps the relevant logs, and records the name.
# Usage: mark_fail <test_name> <log_file...>
#
mark_fail() {
    local test_name="$1"
    shift
    log_error "$test_name failed"
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILED_TEST_NAMES+=("$test_name")
    local log_file
    for log_file in "$@"; do
        if [ -f "$log_file" ]; then
            echo "---------- $log_file ----------"
            cat "$log_file"
            echo "---------- end $log_file ----------"
        fi
    done
}

# ============================================================================
# Test 1: CLI sender -> Desktop receiver (secret)
# ============================================================================
test_cli_to_desktop_secret() {
    local test_name="cli-to-desktop-secret"
    print_test_header 1 "$test_name"
    local test_tmp="$TMP_ROOT/$test_name"
    rm -rf "$test_tmp"
    mkdir -p "$test_tmp/desktop/vault" "$test_tmp/desktop/config" \
             "$test_tmp/cli/vault" "$test_tmp/cli/config"

    seed_secret "$test_tmp/cli/vault" "shared-api-key" "api-key" "API_VALUE_FROM_CLI"

    local code="1234"
    local app_port
    app_port=$(find_free_port)

    start_app "$app_port" "$test_tmp/desktop" 0
    wait_for_ready "$app_port" || { mark_fail "$test_name" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    send_command "$app_port" navigate '{"page":"secrets"}'
    wait_for_log "$test_tmp/desktop" "Secrets page loaded" || { mark_fail "$test_name" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    send_command "$app_port" click '{"dataId":"receive-secret-button"}'
    wait_for_log "$test_tmp/desktop" "Receive secret dialog opened" || { mark_fail "$test_name" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    send_command "$app_port" type "{\"dataId\":\"receive-secret-code-input\",\"text\":\"$code\"}"
    send_command "$app_port" click '{"dataId":"receive-secret-start-button"}'

    sleep 1
    local sender_log="$test_tmp/cli-sender.log"
    run_cli_sender "secrets" "$test_tmp/cli/vault" "$test_tmp/cli/config" "$sender_log" "$code" "shared-api-key"

    if ! grep -q "sent successfully" "$sender_log" 2>/dev/null; then
        mark_fail "$test_name" "$sender_log" "$test_tmp/desktop/app.log"
        stop_app "$app_port" "$test_tmp/desktop"
        return
    fi

    wait_for_log "$test_tmp/desktop" "Secret review step" "$LAN_TIMEOUT" || { mark_fail "$test_name" "$sender_log" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    send_command "$app_port" click '{"dataId":"receive-secret-save-button"}'
    wait_for_log "$test_tmp/desktop" "Secret saved" || { mark_fail "$test_name" "$sender_log" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    if [ ! -f "$test_tmp/desktop/vault/shared-api-key.json" ] || ! grep -q "shared-api-key" "$test_tmp/desktop/vault/shared-api-key.json"; then
        mark_fail "$test_name" "$sender_log" "$test_tmp/desktop/app.log"
        stop_app "$app_port" "$test_tmp/desktop"
        return
    fi

    stop_app "$app_port" "$test_tmp/desktop"
    mark_pass "$test_name"
}

# ============================================================================
# Test 2: CLI sender -> Desktop receiver (database + linked secrets)
# ============================================================================
test_cli_to_desktop_database() {
    local test_name="cli-to-desktop-database"
    print_test_header 2 "$test_name"
    local test_tmp="$TMP_ROOT/$test_name"
    rm -rf "$test_tmp"
    mkdir -p "$test_tmp/desktop/vault" "$test_tmp/desktop/config" \
             "$test_tmp/cli/vault" "$test_tmp/cli/config"

    seed_secret "$test_tmp/cli/vault" "s3-cli-key" "s3-credentials" \
        '{"region":"us-east-1","accessKeyId":"AKIATEST","secretAccessKey":"secret123","endpoint":"http://localhost:9000"}'
    seed_encryption_key "$test_tmp/cli/vault" "enc-cli-key"
    seed_databases_json "$test_tmp/cli/config" "cli-shared-db" "s3:test-bucket:/photos" "s3-cli-key" "enc-cli-key"

    local code="2345"
    local app_port
    app_port=$(find_free_port)

    start_app "$app_port" "$test_tmp/desktop" 0
    wait_for_ready "$app_port" || { mark_fail "$test_name" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    send_command "$app_port" navigate '{"page":"databases"}'
    wait_for_log "$test_tmp/desktop" "Databases page loaded" || { mark_fail "$test_name" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    send_command "$app_port" click '{"dataId":"receive-database-button"}'
    wait_for_log "$test_tmp/desktop" "Receive database dialog opened" || { mark_fail "$test_name" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    send_command "$app_port" type "{\"dataId\":\"receive-database-code-input\",\"text\":\"$code\"}"
    send_command "$app_port" click '{"dataId":"receive-database-start-button"}'

    sleep 1
    local sender_log="$test_tmp/cli-sender.log"
    run_cli_sender "dbs" "$test_tmp/cli/vault" "$test_tmp/cli/config" "$sender_log" "$code" "cli-shared-db"

    if ! grep -q "sent successfully" "$sender_log" 2>/dev/null; then
        mark_fail "$test_name" "$sender_log" "$test_tmp/desktop/app.log"
        stop_app "$app_port" "$test_tmp/desktop"
        return
    fi

    wait_for_log "$test_tmp/desktop" "Database review step" "$LAN_TIMEOUT" || { mark_fail "$test_name" "$sender_log" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    send_command "$app_port" click '{"dataId":"receive-database-save-button"}'
    wait_for_log "$test_tmp/desktop" "Database imported" || { mark_fail "$test_name" "$sender_log" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    if [ ! -f "$test_tmp/desktop/config/databases.toml" ] || ! grep -q "cli-shared-db" "$test_tmp/desktop/config/databases.toml"; then
        mark_fail "$test_name" "$sender_log" "$test_tmp/desktop/app.log"
        stop_app "$app_port" "$test_tmp/desktop"
        return
    fi

    if [ ! -f "$test_tmp/desktop/vault/s3-cli-key.json" ] || [ ! -f "$test_tmp/desktop/vault/enc-cli-key.json" ]; then
        mark_fail "$test_name" "$sender_log" "$test_tmp/desktop/app.log"
        stop_app "$app_port" "$test_tmp/desktop"
        return
    fi

    stop_app "$app_port" "$test_tmp/desktop"
    mark_pass "$test_name"
}

# ============================================================================
# Test 3: Desktop sender -> CLI receiver (secret)
# ============================================================================
test_desktop_to_cli_secret() {
    local test_name="desktop-to-cli-secret"
    print_test_header 3 "$test_name"
    local test_tmp="$TMP_ROOT/$test_name"
    rm -rf "$test_tmp"
    mkdir -p "$test_tmp/desktop/vault" "$test_tmp/desktop/config" \
             "$test_tmp/cli/vault" "$test_tmp/cli/config"

    seed_secret "$test_tmp/desktop/vault" "desktop-api-key" "api-key" "API_VALUE_FROM_DESKTOP"

    local app_port
    app_port=$(find_free_port)

    start_app "$app_port" "$test_tmp/desktop" 0
    wait_for_ready "$app_port" || { mark_fail "$test_name" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    send_command "$app_port" navigate '{"page":"secrets"}'
    wait_for_log "$test_tmp/desktop" "Secrets page loaded" || { mark_fail "$test_name" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    send_command "$app_port" click '{"dataId":"share-secret-button"}'
    send_command "$app_port" click '{"dataId":"share-secret-send-button"}'

    local code
    code=$(read_desktop_pairing_code "$app_port") || { mark_fail "$test_name" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }
    log_info "Desktop pairing code: $code"

    local receiver_log="$test_tmp/cli-receiver.log"
    start_cli_receiver "secrets" "$test_tmp/cli/vault" "$test_tmp/cli/config" "$receiver_log" "$code" || { mark_fail "$test_name" "$receiver_log" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    local elapsed=0
    while [ "$elapsed" -lt "$LAN_TIMEOUT" ]; do
        if grep -q "imported successfully" "$receiver_log" 2>/dev/null; then
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if ! grep -q "imported successfully" "$receiver_log" 2>/dev/null; then
        mark_fail "$test_name" "$receiver_log" "$test_tmp/desktop/app.log"
        cleanup_cli_pids
        stop_app "$app_port" "$test_tmp/desktop"
        return
    fi

    if [ ! -f "$test_tmp/cli/vault/desktop-api-key.json" ] || ! grep -q "desktop-api-key" "$test_tmp/cli/vault/desktop-api-key.json"; then
        mark_fail "$test_name" "$receiver_log" "$test_tmp/desktop/app.log"
        cleanup_cli_pids
        stop_app "$app_port" "$test_tmp/desktop"
        return
    fi

    cleanup_cli_pids
    stop_app "$app_port" "$test_tmp/desktop"
    mark_pass "$test_name"
}

# ============================================================================
# Test 4: Desktop sender -> CLI receiver (database + linked secrets)
# ============================================================================
test_desktop_to_cli_database() {
    local test_name="desktop-to-cli-database"
    print_test_header 4 "$test_name"
    local test_tmp="$TMP_ROOT/$test_name"
    rm -rf "$test_tmp"
    mkdir -p "$test_tmp/desktop/vault" "$test_tmp/desktop/config" \
             "$test_tmp/cli/vault" "$test_tmp/cli/config"

    seed_secret "$test_tmp/desktop/vault" "s3-desktop-key" "s3-credentials" \
        '{"region":"us-east-1","accessKeyId":"AKIATEST","secretAccessKey":"secret123","endpoint":"http://localhost:9000"}'
    seed_encryption_key "$test_tmp/desktop/vault" "enc-desktop-key"
    seed_databases_toml "$test_tmp/desktop/config" "desktop-shared-db" "s3:desktop-bucket:/photos" "s3-desktop-key" "enc-desktop-key"

    local app_port
    app_port=$(find_free_port)

    start_app "$app_port" "$test_tmp/desktop" 0
    wait_for_ready "$app_port" || { mark_fail "$test_name" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    send_command "$app_port" navigate '{"page":"databases"}'
    wait_for_log "$test_tmp/desktop" "Databases page loaded" || { mark_fail "$test_name" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    send_command "$app_port" click '{"dataId":"share-database-button"}'
    send_command "$app_port" click '{"dataId":"share-database-send-button"}'

    local code
    code=$(read_desktop_pairing_code "$app_port") || { mark_fail "$test_name" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }
    log_info "Desktop pairing code: $code"

    local receiver_log="$test_tmp/cli-receiver.log"
    start_cli_receiver "dbs" "$test_tmp/cli/vault" "$test_tmp/cli/config" "$receiver_log" "$code" || { mark_fail "$test_name" "$receiver_log" "$test_tmp/desktop/app.log"; stop_app "$app_port" "$test_tmp/desktop"; return; }

    local elapsed=0
    while [ "$elapsed" -lt "$LAN_TIMEOUT" ]; do
        if grep -q "imported successfully" "$receiver_log" 2>/dev/null; then
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if ! grep -q "imported successfully" "$receiver_log" 2>/dev/null; then
        mark_fail "$test_name" "$receiver_log" "$test_tmp/desktop/app.log"
        cleanup_cli_pids
        stop_app "$app_port" "$test_tmp/desktop"
        return
    fi

    if [ ! -f "$test_tmp/cli/config/databases.toml" ] || ! grep -q "desktop-shared-db" "$test_tmp/cli/config/databases.toml"; then
        mark_fail "$test_name" "$receiver_log" "$test_tmp/desktop/app.log"
        cleanup_cli_pids
        stop_app "$app_port" "$test_tmp/desktop"
        return
    fi

    if [ ! -f "$test_tmp/cli/vault/s3-desktop-key.json" ] || [ ! -f "$test_tmp/cli/vault/enc-desktop-key.json" ]; then
        mark_fail "$test_name" "$receiver_log" "$test_tmp/desktop/app.log"
        cleanup_cli_pids
        stop_app "$app_port" "$test_tmp/desktop"
        return
    fi

    cleanup_cli_pids
    stop_app "$app_port" "$test_tmp/desktop"
    mark_pass "$test_name"
}

# ============================================================================
# Main
# ============================================================================

rm -rf "$TMP_ROOT"
mkdir -p "$TMP_ROOT"

bundle_desktop

SUITE_START=$SECONDS

test_cli_to_desktop_secret
test_cli_to_desktop_database
test_desktop_to_cli_secret
test_desktop_to_cli_database

SUITE_ELAPSED=$(( SECONDS - SUITE_START ))

echo ""
echo "============================================================================"
if [ "$TESTS_FAILED" -eq 0 ]; then
    echo "All $TESTS_PASSED tests passed (${SUITE_ELAPSED}s)"
else
    echo "$TESTS_FAILED of $(( TESTS_PASSED + TESTS_FAILED )) tests failed (${SUITE_ELAPSED}s)"
    echo "Failed tests:"
    for t in "${FAILED_TEST_NAMES[@]}"; do
        echo "  - $t"
    done
fi
echo "============================================================================"

exit "$TESTS_FAILED"
