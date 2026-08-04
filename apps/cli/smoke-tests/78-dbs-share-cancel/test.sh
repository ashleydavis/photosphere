#!/bin/bash
DESCRIPTION="Ctrl+C cancels psi dbs send and psi dbs receive, and both work again afterwards"

# The CLI's only cancellable operations are the two LAN-share commands: each installs a SIGINT
# handler while it waits on the network (dbs.ts sigintHandler, calling sender.cancel/receiver.cancel).
# Ctrl+C is therefore a real code path with nothing else covering it, and a cancel that left a socket
# bound or a broadcast running would stop the next attempt dead.
#
# The signal has to reach the CLI itself. `bun run start --` spawns the CLI as a grandchild and does
# not forward SIGINT, so signalling that wrapper leaves the command running: each command here is
# started with setsid, in its own process group, and the group is signalled the way a terminal
# signals a foreground job on Ctrl+C.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

# Process group of the command started by start_share_command, signalled by cancel_share_command.
SHARE_PGID=""

# LAN-share discovery is machine-wide: every receiver on this host broadcasts on the same UDP port and
# a sender pairs with whichever one answers with a matching code. A fixed code would let this test
# pair with the receiver belonging to another share test, or to another checkout's run, so the code is
# drawn per run. The database name carries the same code because `dbs receive` refuses a name already
# in its list, and the receiver config outlives a run.
PAIRING_CODE=$(( (RANDOM % 9000) + 1000 ))
SHARED_DB_NAME="shared-db-$PAIRING_CODE"

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

test_dbs_share_cancel() {
    local test_number="$1"
    print_test_header "$test_number" "DBS SHARE CANCEL"

    local saved_vault="$PHOTOSPHERE_VAULT_DIR"
    local saved_config="$PHOTOSPHERE_CONFIG_DIR"
    local test_dir="$TEST_TMP_DIR/dbs-share-cancel"
    local sender_vault="$test_dir/sender-vault"
    local sender_config="$test_dir/sender-config"
    local receiver_vault="$test_dir/receiver-vault"
    local receiver_config="$test_dir/receiver-config"
    mkdir -p "$sender_vault" "$sender_config" "$receiver_vault" "$receiver_config"

    export PHOTOSPHERE_VAULT_DIR="$sender_vault"
    export PHOTOSPHERE_CONFIG_DIR="$sender_config"
    seed_databases_config "[{\"name\":\"$SHARED_DB_NAME\",\"description\":\"\",\"path\":\"$test_dir/shared-db\"}]"

    local cli_command
    cli_command=$(get_cli_command)
    local sender_log="$test_dir/sender.log"
    local receiver_log="$test_dir/receiver.log"

    # --- 1. Cancel a sender that is waiting for a receiver. ---

    start_share_command "$sender_log" "Pairing code" \
        env PHOTOSPHERE_VAULT_DIR="$sender_vault" PHOTOSPHERE_CONFIG_DIR="$sender_config" \
        $cli_command dbs send --yes --name "$SHARED_DB_NAME" --code "$PAIRING_CODE" || return 1
    log_success "Sender is waiting for a receiver"

    cancel_share_command || return 1
    log_success "Ctrl+C stopped the waiting sender"

    # --- 2. Cancel a receiver that is waiting for a sender. ---

    start_share_command "$receiver_log" "Waiting for sender" \
        env PHOTOSPHERE_VAULT_DIR="$receiver_vault" PHOTOSPHERE_CONFIG_DIR="$receiver_config" \
        $cli_command dbs receive --yes --code "$PAIRING_CODE" || return 1
    log_success "Receiver is waiting for a sender"

    cancel_share_command || return 1
    log_success "Ctrl+C stopped the waiting receiver"

    # --- 3. Both commands must still work after being cancelled. ---

    start_share_command "$receiver_log" "Waiting for sender" \
        env PHOTOSPHERE_VAULT_DIR="$receiver_vault" PHOTOSPHERE_CONFIG_DIR="$receiver_config" \
        $cli_command dbs receive --yes --code "$PAIRING_CODE" || return 1

    # The receiver's UDP broadcast and HTTPS listener come up just after it says it is waiting.
    sleep 1

    PHOTOSPHERE_VAULT_DIR="$sender_vault" PHOTOSPHERE_CONFIG_DIR="$sender_config" \
        $cli_command dbs send --yes --name "$SHARED_DB_NAME" --code "$PAIRING_CODE" > "$sender_log" 2>&1

    if ! grep -q "sent successfully" "$sender_log"; then
        log_error "The send started after a cancelled one did not report success"
        cat "$sender_log" 2>/dev/null || true
        cancel_share_command
        return 1
    fi

    # Wait for the receiver to write its entry and exit of its own accord.
    local attempt
    for attempt in $(seq 1 40); do
        sleep 0.5
        if ! pgrep -g "$SHARE_PGID" > /dev/null 2>&1; then
            SHARE_PGID=""
            break
        fi
    done

    if ! grep -q "imported successfully" "$receiver_log"; then
        log_error "The receive started after a cancelled one did not import the database"
        cat "$receiver_log" 2>/dev/null || true
        cancel_share_command
        return 1
    fi

    if ! grep -q "$SHARED_DB_NAME" "$receiver_config/databases.toml" 2>/dev/null; then
        log_error "The receiver's database list has no entry after the restarted transfer"
        return 1
    fi
    log_success "A send and a receive started after cancelled ones completed a real transfer"

    export PHOTOSPHERE_VAULT_DIR="$saved_vault"
    export PHOTOSPHERE_CONFIG_DIR="$saved_config"

    test_passed
}

test_dbs_share_cancel "${1:-78}"
