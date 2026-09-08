#!/bin/bash

# Switching automatic import on with access to only the photos the user picked.
#
# Android 14 added a third answer to the photo permission, between allow and deny: the user picks
# individual photos and the app sees those and nothing else. That is not the backup the toggle
# promises, so it is treated as a refusal is treated, and the setting goes back off. What is
# different is what the app says: the user has granted something, and the thing to change is which
# photos rather than whether Photosphere may see any.
#
# The partial grant is set up from outside the app, because a test can no more tap the photo picker
# than it can tap the permission dialog. Revoking the per-type permissions and marking them
# user-fixed, then granting the selected-photos one, is the state the platform leaves behind when a
# user chooses "Select photos". Everything above that is the app's own code under test.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 54 "auto-import-partial-permission"

# Android only. iOS has its own limited-photos answer, but the simulator's photo permissions are set
# through `simctl privacy`, which this machine cannot run or check, so 47 and 48 skip there too.
if [ "$PLATFORM" != "android" ]; then
    log_info "SKIP: this test sets up partial photo access through Android's permission flags. The iOS equivalent has not been written or run."
    exit "$TEST_SKIPPED_EXIT_CODE"
fi

# Partial access needs Android 14. On anything older there is no such answer to set up, and running
# the refusal path under this name would be a test that cannot fail when partial access breaks.
android_sdk="$(adb shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
if [ "${android_sdk:-0}" -lt 34 ]; then
    log_info "SKIP: partial photo access arrived in Android 14 (API 34) and this device is API ${android_sdk:-unknown}."
    exit "$TEST_SKIPPED_EXIT_CODE"
fi

# The permission flags are stored against the app on the device and outlive this test, so they are
# cleared on the way out. Clearing the app's data is what drops them: a later test would otherwise
# inherit a half-granted photo permission it never asked for.
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

# Give the app the photos a user picked, and nothing else.
android_grant_partial_media_permission || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

send_command "$APP_PORT" menu '{"itemId":"open-configuration"}' || exit 1
wait_for_log "$TMP_DIR" "Automatic import settings loaded"

send_command "$APP_PORT" click '{"dataId":"auto-import-toggle"}' || exit 1

# The setting goes back off, saying what a user can act on: which photos, not whether.
wait_for_log "$TMP_DIR" "Automatic import switched off: Photosphere can see only the photos you picked" 60 || exit 1

# And it is not reported as a flat refusal. A partial grant sent through the denied path would tell
# the user to grant a permission they have already granted.
if grep -q "Automatic import switched off: Photosphere needs permission to read your photos" "$TMP_DIR/app.log"; then
    log_error "Partial photo access was reported as a refusal, so the user is told to grant a permission they have already granted."
    exit 1
fi

# Nothing was started. The permission is asked for before the native loop is, so this leaves no
# service running, no database created and no import queued.
if grep -q "Starting automatic import." "$TMP_DIR/app.log"; then
    log_error "Automatic import was started even though the app can see only the photos the user picked."
    exit 1
fi

if adb shell dumpsys activity services "$APP_ID" 2>/dev/null | tr -d '\r' | grep -q "AutoImportService"; then
    log_error "The background import service is running even though the app can see only the photos the user picked."
    exit 1
fi

check_no_errors "$TMP_DIR" || exit 1

log_success "Test 54 passed: auto-import-partial-permission"
