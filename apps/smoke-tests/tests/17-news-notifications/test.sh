#!/bin/bash

# Mobile port of desktop 17-news-notifications. The desktop test feeds a news.yaml via the
# PHOTOSPHERE_NEWS_URL env var (read by the Node main process) and checks the toast lifecycle.
# Mobile has no Node main process to read that env var or fetch a host file, so this port simply
# expects a news notification toast to appear, surfacing whether the news feature is wired on
# mobile at all. Full lifecycle coverage needs a device-served news feed and is follow-up work.

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TEST_DIR/../../lib/common.sh"

print_test_header 17 "news-notifications"

trap 'stop_app "$APP_PORT" "$TMP_DIR"' EXIT

# Wipe everything the app has stored on the device (its storage sandbox, the WebView's
# localStorage and the keychain) so this test starts from a known state. Done before launch,
# with the app stopped, so nothing can write state back underneath it.
"${PLATFORM}_reset_app_state" || exit 1

start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"

# Seed a news item (desktop feeds news.yaml via PHOTOSPHERE_NEWS_URL; on mobile the news feed is
# seeded via the test driver). Seeding shows the first unshown item as a toast.
send_command "$APP_PORT" seed-news '{"news":[{"id":"smoke-news-001","message":"Smoke test news item"}]}' || exit 1

wait_for_log "$TMP_DIR" "Showed news notification:"

send_command "$APP_PORT" click '{"dataId":"toast-dismiss"}' || exit 1
wait_for_log "$TMP_DIR" "Marked news notification as shown:"

check_no_errors "$TMP_DIR"

log_success "Test 17 passed: news-notifications"
