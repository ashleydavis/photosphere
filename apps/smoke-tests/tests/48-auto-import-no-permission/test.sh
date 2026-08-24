#!/bin/bash

# Switching automatic import on without the photo permission.
#
# Without permission the photo library reads nothing, so a toggle left in the on position would be a
# promise the app cannot keep: it would look as though photos were being backed up while none could
# even be seen. The setting has to go back off and say why.
#
# The permission is refused from outside the app rather than by tapping the system dialog, which a
# test cannot do. Revoking it and marking it user-fixed is what the system does when a user chooses
# "Don't allow" and means it: the next request is answered "denied" without a dialog. Everything
# above that is the app's own code under test.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 48 "auto-import-no-permission"

# Android only, for the same reason as 47: the iOS simulator's photo permission is granted and
# revoked through `simctl privacy`, which this machine cannot run or check.
if [ "$PLATFORM" != "android" ]; then
    log_info "SKIP: this test refuses the photo permission through Android's permission flags. The iOS equivalent has not been written or run."
    exit "$TEST_SKIPPED_EXIT_CODE"
fi

# The refusal is stored against the app on the device and outlives this test, so it is cleared on the
# way out. Clearing the app's data is what drops it: a later test that never asks about photos would
# otherwise inherit a permission the user is taken to have refused for good.
on_exit() {
    local exit_code=$?
    stop_app "$APP_PORT" "$TMP_DIR"
    "${PLATFORM}_reset_app_state" >/dev/null 2>&1 || true
    return $exit_code
}
trap on_exit EXIT

# Wipe everything the app has stored on the device, so the toggle starts off and there is no default
# database. Done before launch, with the app stopped, so nothing writes state back underneath it.
"${PLATFORM}_reset_app_state" || exit 1

# Refuse the photo permission, as a user who chose "Don't allow" and meant it.
"${PLATFORM}_refuse_media_permission" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" menu '{"itemId":"open-configuration"}' || exit 1
wait_for_log "$TMP_DIR" "Automatic import settings loaded"

send_command "$APP_PORT" click '{"dataId":"auto-import-toggle"}' || exit 1

# The setting goes back off, and says why in words a user could act on.
wait_for_log "$TMP_DIR" "Automatic import switched off: Photosphere needs permission to read your photos" 60 || exit 1

# And nothing was started. The permission is asked for before the native loop is, so a refusal leaves
# no service running, no database created and no import queued: everything a pass would have done
# happens after this point, and it is never reached.
if grep -q "Starting automatic import." "$TMP_DIR/app.log"; then
    log_error "Automatic import was started even though the photo permission was refused."
    exit 1
fi

if [ "$PLATFORM" = "android" ] && adb shell dumpsys activity services "$APP_ID" 2>/dev/null | tr -d '\r' | grep -q "AutoImportService"; then
    log_error "The background import service is running even though the photo permission was refused."
    exit 1
fi

check_no_errors "$TMP_DIR" || exit 1

log_success "Test 48 passed: auto-import-no-permission"
