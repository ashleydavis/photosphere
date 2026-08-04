#!/bin/bash
DESCRIPTION="Ctrl+C cancels psi secrets send and psi secrets receive, and both work again afterwards"

# The secret half of 78. secrets.ts installs the same pair of SIGINT handlers around the same two
# waits, so both commands are cancellable and neither had anything covering that path.
#
# As in 78 the signal has to reach the CLI rather than the `bun run start --` wrapper, which does not
# forward it, so each command runs in its own process group and the group is signalled.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

# Process group of the command started by start_share_command, signalled by cancel_share_command.
SHARE_PGID=""

# LAN-share discovery is machine-wide: every receiver on this host broadcasts on the same UDP port and
# a sender pairs with whichever one answers with a matching code. A fixed code would let this test
# pair with the receiver belonging to another share test, or to another checkout's run, so the code is
# drawn per run. The secret name carries the same code because the vault outlives a run and a name
# already in it would be refused.
PAIRING_CODE=$(( (RANDOM % 9000) + 1000 ))
SHARED_SECRET_NAME="shared-key-$PAIRING_CODE"

#
# Starts a share command in its own process group, writing its output to the given log, and waits
# until that log contains the given readiness marker.
# Sets SHARE_PGID to the new process group. Returns non-zero if the marker never appeared.
#
start_share_command() {
    local log_file="$1"
    local marker="$2"
    shift 2

    : > "$log_file"
    setsid "$@" > "$log_file" 2>&1 &
    local command_pid=$!

    SHARE_PGID=$(ps -o pgid= -p "$command_pid" | tr -d ' ')
    if [ -z "$SHARE_PGID" ]; then
        log_error "Could not read the process group of the share command"
        return 1
    fi

    local attempt
    for attempt in $(seq 1 60); do
        sleep 0.5
        if grep -q "$marker" "$log_file" 2>/dev/null; then
            return 0
        fi
    done

    log_error "Share command never reported '$marker'"
    cat "$log_file" 2>/dev/null || true
    return 1
}

#
# Sends SIGINT to the process group started by start_share_command, the way Ctrl+C would, and waits
# for every process in it to exit. Returns non-zero if anything is still running afterwards.
#
cancel_share_command() {
    if [ -z "$SHARE_PGID" ] || [ "$SHARE_PGID" -le 1 ]; then
        log_error "Refusing to signal process group '$SHARE_PGID'"
        return 1
    fi

    kill -INT -"$SHARE_PGID"

    local attempt
    for attempt in $(seq 1 40); do
        sleep 0.5
        if ! pgrep -g "$SHARE_PGID" > /dev/null 2>&1; then
            SHARE_PGID=""
            return 0
        fi
    done

    log_error "The share command was still running 20s after Ctrl+C"
    return 1
}

test_secrets_share_cancel() {
    local test_number="$1"
    print_test_header "$test_number" "SECRETS SHARE CANCEL"

    local saved_vault="$PHOTOSPHERE_VAULT_DIR"
    local saved_config="$PHOTOSPHERE_CONFIG_DIR"
    local test_dir="$TEST_TMP_DIR/secrets-share-cancel"
    local sender_vault="$test_dir/sender-vault"
    local sender_config="$test_dir/sender-config"
    local receiver_vault="$test_dir/receiver-vault"
    local receiver_config="$test_dir/receiver-config"
    mkdir -p "$sender_vault" "$sender_config" "$receiver_vault" "$receiver_config"

    local cli_command
    cli_command=$(get_cli_command)
    local sender_log="$test_dir/sender.log"
    local receiver_log="$test_dir/receiver.log"

    PHOTOSPHERE_VAULT_DIR="$sender_vault" PHOTOSPHERE_CONFIG_DIR="$sender_config" \
        $cli_command secrets add --yes --name "$SHARED_SECRET_NAME" --type api-key --value SHAREDVALUE123 > /dev/null 2>&1

    # --- 1. Cancel a sender that is waiting for a receiver. ---

    start_share_command "$sender_log" "Pairing code" \
        env PHOTOSPHERE_VAULT_DIR="$sender_vault" PHOTOSPHERE_CONFIG_DIR="$sender_config" \
        $cli_command secrets send --yes --name "$SHARED_SECRET_NAME" --code "$PAIRING_CODE" || return 1
    log_success "Sender is waiting for a receiver"

    cancel_share_command || return 1
    log_success "Ctrl+C stopped the waiting sender"

    # --- 2. Cancel a receiver that is waiting for a sender. ---

    start_share_command "$receiver_log" "Waiting for sender" \
        env PHOTOSPHERE_VAULT_DIR="$receiver_vault" PHOTOSPHERE_CONFIG_DIR="$receiver_config" \
        $cli_command secrets receive --yes --code "$PAIRING_CODE" || return 1
    log_success "Receiver is waiting for a sender"

    cancel_share_command || return 1
    log_success "Ctrl+C stopped the waiting receiver"

    # --- 3. Both commands must still work after being cancelled. ---

    start_share_command "$receiver_log" "Waiting for sender" \
        env PHOTOSPHERE_VAULT_DIR="$receiver_vault" PHOTOSPHERE_CONFIG_DIR="$receiver_config" \
        $cli_command secrets receive --yes --code "$PAIRING_CODE" || return 1

    # The receiver's UDP broadcast and HTTPS listener come up just after it says it is waiting.
    sleep 1

    PHOTOSPHERE_VAULT_DIR="$sender_vault" PHOTOSPHERE_CONFIG_DIR="$sender_config" \
        $cli_command secrets send --yes --name "$SHARED_SECRET_NAME" --code "$PAIRING_CODE" > "$sender_log" 2>&1

    if ! grep -q "sent successfully" "$sender_log"; then
        log_error "The send started after a cancelled one did not report success"
        cat "$sender_log" 2>/dev/null || true
        cancel_share_command
        return 1
    fi

    # Wait for the receiver to write the secret and exit of its own accord.
    local attempt
    for attempt in $(seq 1 40); do
        sleep 0.5
        if ! pgrep -g "$SHARE_PGID" > /dev/null 2>&1; then
            SHARE_PGID=""
            break
        fi
    done

    if ! grep -q "imported successfully" "$receiver_log"; then
        log_error "The receive started after a cancelled one did not import the secret"
        cat "$receiver_log" 2>/dev/null || true
        cancel_share_command
        return 1
    fi

    local received_secrets
    received_secrets=$(find "$receiver_vault" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)
    if [ "$received_secrets" -lt 1 ]; then
        log_error "The receiver's vault is empty after the restarted transfer"
        return 1
    fi
    log_success "A send and a receive started after cancelled ones completed a real transfer"

    export PHOTOSPHERE_VAULT_DIR="$saved_vault"
    export PHOTOSPHERE_CONFIG_DIR="$saved_config"

    test_passed
}

test_secrets_share_cancel "${1:-79}"
