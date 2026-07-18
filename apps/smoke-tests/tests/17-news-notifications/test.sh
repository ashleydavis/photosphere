#!/bin/bash

# News notification toast lifecycle. Electron feeds news.yaml via PHOTOSPHERE_NEWS_URL and
# runs the full three-startup lifecycle (show, dismiss, persist, no-repeat). Mobile seeds a
# single news item via seed-news and asserts show + dismiss.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 17 "news-notifications"

TMP_DIR="$TEST_DIR/tmp"

if [ "$PLATFORM" = "electron" ]; then
    cleanup() {
        stop_app "${APP_PORT:-}" "$TMP_DIR" 2>/dev/null || true
    }
    trap cleanup EXIT

    mkdir -p "$TMP_DIR/config"

    log_info "Writing test news.yaml with two items..."
    cat > "$TMP_DIR/news.yaml" <<'EOF'
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
EOF

    export PHOTOSPHERE_NEWS_URL="file://$TMP_DIR/news.yaml"

    # ========================================================================
    # First startup: should show smoke-test-001 only, and NOT persist until dismissed
    # ========================================================================
    log_info "First startup..."
    start_app "$TMP_DIR"
    wait_for_ready "$APP_PORT"

    wait_for_log "$TMP_DIR" "Showed news notification: smoke-test-001"

    if grep -q "smoke-test-002" "$TMP_DIR/app.log"; then
        log_error "smoke-test-002 unexpectedly logged during first startup"
        exit 1
    fi

    STATE_FILE="$TMP_DIR/config/news.yaml"
    if [ -f "$STATE_FILE" ] && grep -q 'smoke-test-001' "$STATE_FILE"; then
        log_error "news.yaml unexpectedly persisted smoke-test-001 before user dismissed the toast"
        cat "$STATE_FILE"
        exit 1
    fi

    log_info "Dismissing the news toast..."
    send_command "$APP_PORT" click '{"dataId":"toast-dismiss"}' || exit 1
    wait_for_log "$TMP_DIR" "Marked news notification as shown: smoke-test-001"

    if ! grep -q 'smoke-test-001' "$STATE_FILE"; then
        log_error "news.yaml does not contain smoke-test-001 after dismissal"
        cat "$STATE_FILE"
        exit 1
    fi
    if grep -q 'smoke-test-002' "$STATE_FILE"; then
        log_error "news.yaml unexpectedly contains smoke-test-002 after first startup"
        cat "$STATE_FILE"
        exit 1
    fi

    stop_app "$APP_PORT" "$TMP_DIR"

    # ========================================================================
    # Second startup: should show smoke-test-002 only after dismissal
    # ========================================================================
    log_info "Second startup..."
    rm -f "$TMP_DIR/.log-cursor"
    start_app "$TMP_DIR"
    wait_for_ready "$APP_PORT"

    wait_for_log "$TMP_DIR" "Showed news notification: smoke-test-002"

    if grep -q "Showed news notification: smoke-test-001" "$TMP_DIR/app.log"; then
        log_error "smoke-test-001 was shown again on second startup"
        exit 1
    fi

    if ! grep -q 'smoke-test-001' "$STATE_FILE"; then
        log_error "news.yaml lost smoke-test-001 after second startup"
        cat "$STATE_FILE"
        exit 1
    fi
    if grep -q 'smoke-test-002' "$STATE_FILE"; then
        log_error "news.yaml unexpectedly persisted smoke-test-002 before user dismissed the toast"
        cat "$STATE_FILE"
        exit 1
    fi

    log_info "Dismissing the news toast..."
    send_command "$APP_PORT" click '{"dataId":"toast-dismiss"}' || exit 1
    wait_for_log "$TMP_DIR" "Marked news notification as shown: smoke-test-002"

    if ! grep -q 'smoke-test-002' "$STATE_FILE"; then
        log_error "news.yaml does not contain smoke-test-002 after dismissal"
        cat "$STATE_FILE"
        exit 1
    fi

    stop_app "$APP_PORT" "$TMP_DIR"

    # ========================================================================
    # Third startup: should show nothing (both items already marked seen)
    # ========================================================================
    log_info "Third startup..."
    rm -f "$TMP_DIR/.log-cursor"
    start_app "$TMP_DIR"
    wait_for_ready "$APP_PORT"

    sleep 3

    if grep -q "Showed news notification:" "$TMP_DIR/app.log"; then
        log_error "A news notification was shown on the third startup (expected none)"
        grep "Showed news notification:" "$TMP_DIR/app.log"
        exit 1
    fi

    stop_app "$APP_PORT" "$TMP_DIR"

    check_no_errors "$TMP_DIR"

    log_success "Test 17 passed: news-notifications"
else
    trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

    start_app "$TMP_DIR"
    wait_for_ready "$APP_PORT"

    send_command "$APP_PORT" reset-config '{}' || exit 1
    send_command "$APP_PORT" seed-news '{"news":[{"id":"smoke-news-001","message":"Smoke test news item"}]}' || exit 1

    wait_for_log "$TMP_DIR" "Showed news notification:"

    send_command "$APP_PORT" click '{"dataId":"toast-dismiss"}' || exit 1
    wait_for_log "$TMP_DIR" "Marked news notification as shown:"

    check_no_errors "$TMP_DIR"

    log_success "Test 17 passed: news-notifications"
fi
