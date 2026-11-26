#!/bin/bash

# Automatic import and syncing report as jobs, so while they run the navbar's background jobs indicator counts them and, once the work
# is done, drops back to none. The desktop runs the same background pass as a mobile now, so a job that already showed there has to show
# here too.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 71 "background-jobs"

# Not on iOS. iOS runs its passes when the system decides, and the only way to force one is an lldb command this harness has no way to
# issue on Xcode 14.2.
if [ "$PLATFORM" = "ios" ]; then
    log_info "SKIP: the background jobs are covered on Android and the desktop only, where a pass can be made to run."
    exit "$TEST_SKIPPED_EXIT_CODE"
fi

"${PLATFORM}_claim_device" || exit 1

# The library this run's photos go into, a folder of its own and, on a mobile, an album of its own, so a real mobile's own photos are
# never imported. It holds several distinct photos so the first import pass takes long enough for its job to be observed rather than
# flashing past between polls.
LIBRARY_PREFIX="psphere-background-jobs"
LIBRARY="$("${PLATFORM}_library_dir" "$LIBRARY_PREFIX")"

FIRST_PHOTO_NAME="psphere-background-jobs-$$-one.jpeg"
SECOND_PHOTO_NAME="psphere-background-jobs-$$-two.png"
THIRD_PHOTO_NAME="psphere-background-jobs-$$-three.png"
FOURTH_PHOTO_NAME="psphere-background-jobs-$$-four.jpg"

on_exit() {
    local exit_code=$?
    "${PLATFORM}_library_remove" "$LIBRARY" "$FIRST_PHOTO_NAME" "$SECOND_PHOTO_NAME" "$THIRD_PHOTO_NAME" "$FOURTH_PHOTO_NAME" 2>/dev/null || true
    cleanup_apps "$TMP_DIR"
    return $exit_code
}
trap on_exit EXIT

"${PLATFORM}_reset_app_state" || exit 1
"${PLATFORM}_library_sweep" "$LIBRARY_PREFIX" || exit 1

"${PLATFORM}_library_add" "$LIBRARY" "$REPO_DIR/test/multiple-files/test-1.jpeg" "$FIRST_PHOTO_NAME" || exit 1
"${PLATFORM}_library_add" "$LIBRARY" "$REPO_DIR/test/multiple-files/test-2.png" "$SECOND_PHOTO_NAME" || exit 1
"${PLATFORM}_library_add" "$LIBRARY" "$REPO_DIR/test/test.png" "$THIRD_PHOTO_NAME" || exit 1
"${PLATFORM}_library_add" "$LIBRARY" "$REPO_DIR/test/test.jpg" "$FOURTH_PHOTO_NAME" || exit 1

# Automatic import on before launch, pointed at this library and nothing else, with a short gap between passes.
"${PLATFORM}_seed_library_auto_import_config" "true" "" "1000" "$LIBRARY" "$FIRST_PHOTO_NAME" || exit 1

# The photo and notification permissions, from outside the app, which a mobile needs before the pass can read the library or hold the
# foreground service.
"${PLATFORM}_grant_media_permission" || exit 1
"${PLATFORM}_grant_notification_permission" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# The import is reported as a job: the navbar's machine-readable count rises above zero while it runs.
wait_for_value_matching "$APP_PORT" "navbar-jobs-count" "^[1-9][0-9]*$" 60
log_success "Automatic import was counted as a background job while it ran"

# And the job ends once the import is done, leaving the count at none.
wait_for_value_matching "$APP_PORT" "navbar-jobs-count" "^0$" 60
log_success "The background job cleared once the import finished"

check_no_errors "$TMP_DIR" 'Failed to load asset: thumb:|Network Error'

log_success "Test 71 passed: background-jobs"