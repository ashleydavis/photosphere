#!/usr/bin/env bash

# The theme from --theme reaches the page before it draws, the theme toggle changes it while the app runs, the setting is written to the
# config file, and a restart reads it back.

source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

trap 'cleanup_apps "$TMP_DIR"' EXIT

export PHOTOSPHERE_SMOKE_THEME=dark
start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"
wait_for_attribute "$APP_PORT" "class" "dark" 10
log_success "The dark theme reached the page before it drew"

send_command "$APP_PORT" click '{"dataId":"theme-toggle-button"}' || exit 1
send_command "$APP_PORT" click '{"dataId":"theme-option-light"}' || exit 1
wait_for_attribute "$APP_PORT" "class" "light" 10
log_success "The theme toggle changed the page's colours while it ran"

config_text="$(read_config_file config.toml)" || exit 1
case "$config_text" in
    *'theme = "light"'*) ;;
    *)
        log_error "The config file does not hold the light theme: $config_text"
        exit 1
        ;;
esac
log_success "The setting was written to the config file"

stop_app "$APP_PORT" "$TMP_DIR"
reset_log_cursor "$TMP_DIR"
unset PHOTOSPHERE_SMOKE_THEME
start_app "$TMP_DIR"
wait_for_ready "$APP_PORT"
wait_for_attribute "$APP_PORT" "class" "light" 10
log_success "The restart read the light setting from the config file"

check_no_errors "$TMP_DIR" || exit 1
