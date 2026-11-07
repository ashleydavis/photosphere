#!/bin/bash

# The news feed shows one unseen item per launch as a toast, oldest first, and an item is recorded as shown only when the user dismisses
# its toast. The app is pointed at a feed file through PHOTOSPHERE_NEWS_URL, which is the only way the news check runs in test mode, and
# the feed is placed in the app's settings directory from outside the app. Three launches cover it: the first announces the first item
# and leaves it unrecorded until dismissed, the second announces the second item and not the first, and the third, with a third item
# added to the feed, announces only the third, which proves the first two were recorded and kept.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../lib/common.sh"

print_test_header 17 "news-notifications"

trap 'cleanup_apps "$TMP_DIR"' EXIT

case "$PLATFORM" in
    android|ios)
        # Start from nothing on the device, so no news recorded as shown by an earlier scenario hides an item.
        "${PLATFORM}_reset_app_state" || exit 1
        ;;
esac

log_info "Writing a test news.yaml with two items..."
cat > "$TMP_DIR/news.yaml" <<'YAML'
items:
  - id: smoke-test-001
    message: "Welcome to Photosphere"
    color: success
    link:
      label: "Read more"
      url: "https://example.com/read"
    action:
      label: "Try it"
      url: "https://example.com/try"
  - id: smoke-test-002
    message: "Second item"
YAML
put_config_file "$TMP_DIR/news.yaml" "news.yaml" || exit 1

export PHOTOSPHERE_NEWS_URL="file://$(config_file_path news.yaml)"

# ============================================================================
# First startup: should show smoke-test-001 only, and NOT persist until dismissed
# ============================================================================
log_info "First startup..."
start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

wait_for_log "$TMP_DIR" "Showed news notification: smoke-test-001"

if grep -q "smoke-test-002" "$TMP_DIR/app.log"; then
    log_error "smoke-test-002 unexpectedly logged during first startup"
    exit 1
fi

# Before dismissal the news state file should not record smoke-test-001: the toast is sticky and persistence is deferred until the user
# clicks close.
if read_config_file state.yaml | grep -q 'smoke-test-001'; then
    log_error "the state file unexpectedly persisted smoke-test-001 before user dismissed the toast"
    read_config_file state.yaml
    exit 1
fi

log_info "Dismissing the news toast..."
send_command "$APP_PORT" click '{"dataId":"toast-dismiss"}' || exit 1
wait_for_log "$TMP_DIR" "Marked news notification as shown: smoke-test-001"

if ! read_config_file state.yaml | grep -q 'smoke-test-001'; then
    log_error "the state file does not contain smoke-test-001 after dismissal"
    read_config_file state.yaml
    exit 1
fi
if read_config_file state.yaml | grep -q 'smoke-test-002'; then
    log_error "the state file unexpectedly contains smoke-test-002 after first startup"
    read_config_file state.yaml
    exit 1
fi

stop_app "$APP_PORT" "$TMP_DIR"

# ============================================================================
# Second startup: should show smoke-test-002 only after dismissal
# ============================================================================
log_info "Second startup..."
# The relaunched app starts a fresh app.log, so the cursor from the first run points past the end of it.
reset_log_cursor "$TMP_DIR"
start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

wait_for_log "$TMP_DIR" "Showed news notification: smoke-test-002"

if grep -q "Showed news notification: smoke-test-001" "$TMP_DIR/app.log"; then
    log_error "smoke-test-001 was shown again on second startup"
    exit 1
fi

if ! read_config_file state.yaml | grep -q 'smoke-test-001'; then
    log_error "the state file lost smoke-test-001 after second startup"
    read_config_file state.yaml
    exit 1
fi
if read_config_file state.yaml | grep -q 'smoke-test-002'; then
    log_error "the state file unexpectedly persisted smoke-test-002 before user dismissed the toast"
    read_config_file state.yaml
    exit 1
fi

log_info "Dismissing the news toast..."
send_command "$APP_PORT" click '{"dataId":"toast-dismiss"}' || exit 1
wait_for_log "$TMP_DIR" "Marked news notification as shown: smoke-test-002"

if ! read_config_file state.yaml | grep -q 'smoke-test-002'; then
    log_error "the state file does not contain smoke-test-002 after dismissal"
    read_config_file state.yaml
    exit 1
fi

stop_app "$APP_PORT" "$TMP_DIR"

# ============================================================================
# Third startup: both items are already recorded, so only a third item is announced
# ============================================================================
# Waiting a few seconds to see that nothing is shown would pass on a stopwatch, and would pass for an app whose news check never ran.
# A third item that has not been seen is announced if and only if the first two were skipped, because the oldest unseen item comes
# first, so its announcement is the positive proof that both were recorded.
log_info "Third startup, with a third item in the feed..."
cat >> "$TMP_DIR/news.yaml" <<'YAML'
  - id: smoke-test-003
    message: "Third item"
YAML
put_config_file "$TMP_DIR/news.yaml" "news.yaml" || exit 1

reset_log_cursor "$TMP_DIR"
start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

wait_for_log "$TMP_DIR" "Showed news notification: smoke-test-003"

if grep -q "Showed news notification: smoke-test-00[12]" "$TMP_DIR/app.log"; then
    log_error "An item that was dismissed earlier was shown again on the third startup"
    grep "Showed news notification:" "$TMP_DIR/app.log"
    exit 1
fi
log_success "Only the item not yet seen was announced on the third startup"

stop_app "$APP_PORT" "$TMP_DIR"

check_no_errors "$TMP_DIR"

log_success "Test 17 passed: news-notifications"
