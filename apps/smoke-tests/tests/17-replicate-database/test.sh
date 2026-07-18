#!/bin/bash

# Registers a source database and replicates it. Electron runs partial then full replication
# with host filesystem asserts (origin path, files.dat) and opens both replicas. Mobile runs
# the partial UI flow with sandbox-relative paths.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 17 "replicate-database"

TMP_DIR="$TEST_DIR/tmp"
IMAGES_DIR="$REPO_DIR/test/multiple-files"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

if [ "$PLATFORM" = "electron" ]; then
    SOURCE_DB="$TMP_DIR/source-db"
    DEST_PARTIAL="$TMP_DIR/dest-partial"
    DEST_FULL="$TMP_DIR/dest-full"

    log_info "Pre-creating source database with CLI and importing a fixture..."
    create_database "$SOURCE_DB" "$IMAGES_DIR/test-1.jpeg"

    start_app "$TMP_DIR"
    wait_for_ready "$APP_PORT"

    send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
    wait_for_log "$TMP_DIR" "Databases page loaded"

    send_command "$APP_PORT" click '{"dataId":"add-database-button"}' || exit 1
    wait_for_log "$TMP_DIR" "Add database dialog opened"

    send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"Source DB"}' || exit 1
    send_command "$APP_PORT" type "{\"dataId\":\"database-path-input\",\"text\":\"$SOURCE_DB\"}" || exit 1
    send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}' || exit 1
    wait_for_log "$TMP_DIR" "Database entry added"

    # Partial replication.
    send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
    wait_for_log "$TMP_DIR" "Databases page loaded"

    send_command "$APP_PORT" click '{"dataId":"replicate-database-button"}' || exit 1
    wait_for_log "$TMP_DIR" "Replicate database dialog opened"

    send_command "$APP_PORT" type "{\"dataId\":\"replicate-dest-path-input\",\"text\":\"$DEST_PARTIAL\"}" || exit 1
    send_command "$APP_PORT" click '{"dataId":"replicate-mode-partial"}' || exit 1
    send_command "$APP_PORT" click '{"dataId":"replicate-start-button"}' || exit 1

    wait_for_log "$TMP_DIR" "Replication completed for"

    if [ ! -f "$DEST_PARTIAL/.db/files.dat" ]; then
        log_error "Partial replication did not produce $DEST_PARTIAL/.db/files.dat"
        exit 1
    fi
    if [ ! -f "$DEST_PARTIAL/.db/config.json" ]; then
        log_error "Partial replication did not produce $DEST_PARTIAL/.db/config.json"
        exit 1
    fi
    if ! grep -q "\"origin\"" "$DEST_PARTIAL/.db/config.json"; then
        log_error "Partial replication config.json does not contain origin"
        cat "$DEST_PARTIAL/.db/config.json"
        exit 1
    fi

    EXPECTED_ORIGIN="$SOURCE_DB"
    ACTUAL_ORIGIN=$(grep -oE '"origin"[[:space:]]*:[[:space:]]*"[^"]*"' "$DEST_PARTIAL/.db/config.json" | sed -E 's/.*"origin"[[:space:]]*:[[:space:]]*"([^"]*)"/\1/')
    if [ "$ACTUAL_ORIGIN" != "$EXPECTED_ORIGIN" ]; then
        log_error "Partial replica config.json origin does not match source path."
        log_error "  Expected: $EXPECTED_ORIGIN"
        log_error "  Actual:   $ACTUAL_ORIGIN"
        cat "$DEST_PARTIAL/.db/config.json"
        exit 1
    fi

    log_success "Partial replication produced expected files"

    send_command "$APP_PORT" click '{"dataId":"replicate-close-button"}' || exit 1

    send_command "$APP_PORT" open-database "{\"path\":\"$DEST_PARTIAL\"}" || exit 1
    wait_for_log "$TMP_DIR" "Load assets task completed: 1 assets loaded"
    log_success "Partial replica opened with 1 asset"

    # Full replication.
    send_command "$APP_PORT" navigate '{"page":"secrets"}' || exit 1
    send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
    wait_for_log "$TMP_DIR" "Databases page loaded"

    send_command "$APP_PORT" click '{"dataId":"replicate-database-button"}' || exit 1
    wait_for_log "$TMP_DIR" "Replicate database dialog opened"

    send_command "$APP_PORT" type "{\"dataId\":\"replicate-dest-path-input\",\"text\":\"$DEST_FULL\"}" || exit 1
    send_command "$APP_PORT" click '{"dataId":"replicate-mode-full"}' || exit 1
    send_command "$APP_PORT" click '{"dataId":"replicate-start-button"}' || exit 1

    wait_for_log "$TMP_DIR" "Replication completed for"

    if [ ! -f "$DEST_FULL/.db/files.dat" ]; then
        log_error "Full replication did not produce $DEST_FULL/.db/files.dat"
        exit 1
    fi
    if [ ! -s "$DEST_FULL/.db/files.dat" ]; then
        log_error "Full replication produced an empty files.dat"
        exit 1
    fi
    log_success "Full replication produced expected files"

    send_command "$APP_PORT" click '{"dataId":"replicate-close-button"}' || exit 1

    send_command "$APP_PORT" open-database "{\"path\":\"$DEST_FULL\"}" || exit 1
    wait_for_log "$TMP_DIR" "Load assets task completed: 1 assets loaded"
    log_success "Full replica opened with 1 asset"

    check_no_errors "$TMP_DIR"

    log_success "Test 17 passed: replicate-database"
else
    start_app "$TMP_DIR"
    wait_for_ready "$APP_PORT"

    send_command "$APP_PORT" reset-config '{}' || exit 1
    reset_path "dest-partial"
    create_database "$TMP_DIR/source-db"
    seed_database "$TMP_DIR/source-db" "source-db"

    send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
    wait_for_log "$TMP_DIR" "Databases page loaded"

    send_command "$APP_PORT" click '{"dataId":"page-actions-menu"}' || exit 1
    send_command "$APP_PORT" click '{"dataId":"add-database-button"}' || exit 1
    wait_for_log "$TMP_DIR" "Add database dialog opened"

    send_command "$APP_PORT" type '{"dataId":"database-name-input","text":"Source DB"}' || exit 1
    send_command "$APP_PORT" type '{"dataId":"database-path-input","text":"source-db"}' || exit 1
    send_command "$APP_PORT" click '{"dataId":"add-database-confirm"}' || exit 1
    wait_for_log "$TMP_DIR" "Database entry added"

    send_command "$APP_PORT" navigate '{"page":"databases"}' || exit 1
    wait_for_log "$TMP_DIR" "Databases page loaded"

    send_command "$APP_PORT" click '{"dataId":"entity-actions-menu"}' || exit 1
    send_command "$APP_PORT" click '{"dataId":"replicate-database-button"}' || exit 1
    wait_for_log "$TMP_DIR" "Replicate database dialog opened"

    send_command "$APP_PORT" type '{"dataId":"replicate-dest-path-input","text":"dest-partial"}' || exit 1
    send_command "$APP_PORT" click '{"dataId":"replicate-mode-partial"}' || exit 1
    send_command "$APP_PORT" click '{"dataId":"replicate-start-button"}' || exit 1
    wait_for_log "$TMP_DIR" "Replication completed for"

    check_no_errors "$TMP_DIR"

    log_success "Test 17 passed: replicate-database"
fi
