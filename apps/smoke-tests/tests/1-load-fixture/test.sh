#!/bin/bash

# Loads the checked-in 50-assets fixture and expects the gallery to show 50 assets.
# Electron opens the fixture via an absolute host path. Mobile seeds it into the app
# sandbox and opens it by sandbox-relative name. On Android, also confirms the embedded
# asset server serves a real JPEG thumbnail.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 1 "load-fixture"

TMP_DIR="$TEST_DIR/tmp"
DB_NAME="50-assets"
FIXTURE_DB="$REPO_DIR/test/dbs/$DB_NAME"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

if [ "$PLATFORM" = "electron" ]; then
    send_command "$APP_PORT" open-database "{\"path\":\"$FIXTURE_DB\"}" || exit 1
else
    seed_database "$FIXTURE_DB" "$DB_NAME"
    send_command "$APP_PORT" open-database "{\"path\":\"$DB_NAME\"}" || exit 1
fi

wait_for_log "$TMP_DIR" "Gallery loaded: 50 assets"

check_no_errors "$TMP_DIR" || exit 1

# Directly confirm the embedded asset server serves real thumbnail bytes on device.
if [ "$PLATFORM" = "android" ]; then
    ASSET_ID="$(ls "$FIXTURE_DB/thumb" | head -1)"
    SERVER_PORT="$(adb logcat -d 2>/dev/null | grep -oE 'Asset server task listening on http://127.0.0.1:[0-9]+' | tail -1 | grep -oE '[0-9]+$')"
    if [ -z "$SERVER_PORT" ]; then
        log_error "Asset server did not report a bound port"
        exit 1
    fi
    HOST_PORT="$(adb forward tcp:0 "tcp:$SERVER_PORT")"
    THUMB_OUT="$TMP_DIR/served-thumb.bin"
    HTTP_CODE="$(curl -s -o "$THUMB_OUT" -w '%{http_code}' --max-time 10 "http://localhost:$HOST_PORT/asset?id=$ASSET_ID&type=thumb&db=$DB_NAME")"
    adb forward --remove "tcp:$HOST_PORT" >/dev/null 2>&1 || true
    if [ "$HTTP_CODE" != "200" ]; then
        log_error "Asset server returned HTTP $HTTP_CODE for thumbnail $ASSET_ID"
        exit 1
    fi
    if ! file "$THUMB_OUT" | grep -q "JPEG image data"; then
        log_error "Asset server did not return JPEG thumbnail bytes (got: $(file "$THUMB_OUT"))"
        exit 1
    fi
    log_success "Asset server served a JPEG thumbnail over localhost:$SERVER_PORT"
fi

log_success "Test 1 passed: load-fixture"
