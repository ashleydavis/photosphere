#!/bin/bash

# Opens the checked-in 50-assets fixture and expects the gallery to load 50 assets. On a desktop the fixture is opened from where it sits
# in the repository. On a phone it is copied into the app's storage sandbox first (a host path does not exist on the device) and opened
# by its sandbox-relative name; there the asset server's thumbnail route is also fetched over a forwarded port.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 1 "load-fixture"

FIXTURE_NAME="50-assets"
FIXTURE_DB="$REPO_DIR/test/dbs/$FIXTURE_NAME"

trap 'cleanup_apps "$TMP_DIR"' EXIT

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

case "$PLATFORM" in
    android|ios)
        "${PLATFORM}_seed_database" "$FIXTURE_DB" "$FIXTURE_NAME" || exit 1
        OPEN_PATH="$("${PLATFORM}_app_path" "$FIXTURE_NAME")"
        ;;
    *)
        OPEN_PATH="$FIXTURE_DB"
        ;;
esac

send_command "$APP_PORT" open-database "$(jq -cn --arg path "$OPEN_PATH" '{path: $path}')" || exit 1

wait_for_log "$TMP_DIR" "Gallery loaded: 50 assets"

# The gallery upgrades each tile from its embedded micro-thumbnail to a full thumbnail fetched over the app's asset server, so no
# asset-load errors are tolerated.
check_no_errors "$TMP_DIR"

case "$PLATFORM" in
    android)
        # Directly confirm the asset server serves real thumbnail bytes on the device (the same request the web view makes): read the
        # bound port from the app's log, forward it to the host, and assert a JPEG body.
        ASSET_ID="$(ls "$FIXTURE_DB/thumb" | head -1)"
        SERVER_PORT="$(grep -oE 'Asset server task listening on http://127.0.0.1:[0-9]+' "$TMP_DIR/app.log" | tail -1 | grep -oE '[0-9]+$')"
        if [ -z "$SERVER_PORT" ]; then
            log_error "Asset server did not report a bound port"
            exit 1
        fi
        # Let adb pick and bind the host port atomically (tcp:0 prints the assigned port), so a parallel run cannot grab it in between.
        HOST_PORT="$(photosphere_adb forward tcp:0 "tcp:$SERVER_PORT")"
        THUMB_OUT="$TMP_DIR/served-thumb.bin"
        # The literal loopback address, never the name "localhost", which resolves to ::1 first and could reach an emulator console.
        HTTP_CODE="$(curl -s -o "$THUMB_OUT" -w '%{http_code}' --max-time 10 -G --data-urlencode "id=$ASSET_ID" --data-urlencode "type=thumb" --data-urlencode "db=$OPEN_PATH" "http://127.0.0.1:$HOST_PORT/asset")"
        photosphere_adb forward --remove "tcp:$HOST_PORT" >/dev/null 2>&1 || true
        if [ "$HTTP_CODE" != "200" ]; then
            log_error "Asset server returned HTTP $HTTP_CODE for thumbnail $ASSET_ID"
            exit 1
        fi
        if ! file "$THUMB_OUT" | grep -q "JPEG image data"; then
            log_error "Asset server did not return JPEG thumbnail bytes (got: $(file "$THUMB_OUT"))"
            exit 1
        fi
        log_success "Asset server served a JPEG thumbnail over 127.0.0.1:$HOST_PORT"
        ;;
esac

stop_app "$APP_PORT" "$TMP_DIR"

log_success "Test 1 passed: load-fixture"
