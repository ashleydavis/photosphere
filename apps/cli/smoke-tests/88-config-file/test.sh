#!/bin/bash
DESCRIPTION="Settings go in one config.yaml, the database list stays in its own databases.toml, and neither of the files they replaced comes back"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

# Every setting the app remembers lives in one file now. Before this there were four, in two formats,
# and which one a setting landed in depended on which platform had written it. This test is about the
# files themselves: that the CLI writes config.yaml, that it writes the news state into a section of
# that same file rather than into a news.yaml of its own, and that databases.toml stays the separate
# file it was always meant to be.
#
# It runs with PHOTOSPHERE_CONFIG_DIR pointed at a directory of its own, so it reads and writes the
# settings of nothing but itself. Without that it would be looking at the settings of whoever is
# running it, and every assertion below would depend on what they happen to have configured.

#
# Fails the test unless the named file is in the config directory.
#
expect_config_file() {
    local file_name="$1"
    local description="$2"

    if [ -f "$PHOTOSPHERE_CONFIG_DIR/$file_name" ]; then
        log_success "$description"
        return 0
    fi

    log_error "$description ($file_name is not in $PHOTOSPHERE_CONFIG_DIR)"
    ls -la "$PHOTOSPHERE_CONFIG_DIR" 2>/dev/null || true
    exit 1
}

#
# Fails the test when the named file is in the config directory.
#
expect_no_config_file() {
    local file_name="$1"
    local description="$2"

    if [ ! -f "$PHOTOSPHERE_CONFIG_DIR/$file_name" ]; then
        log_success "$description"
        return 0
    fi

    log_error "$description ($file_name is in $PHOTOSPHERE_CONFIG_DIR and should not be)"
    cat "$PHOTOSPHERE_CONFIG_DIR/$file_name"
    exit 1
}

test_config_file() {
    local test_number="$1"
    print_test_header "$test_number" "CONFIG FILE"

    local saved_vault="$PHOTOSPHERE_VAULT_DIR"
    local saved_config="$PHOTOSPHERE_CONFIG_DIR"
    local test_dir="$TEST_TMP_DIR/config-file"
    rm -rf "$test_dir"
    export PHOTOSPHERE_VAULT_DIR="$test_dir/vault"
    export PHOTOSPHERE_CONFIG_DIR="$test_dir/config"
    mkdir -p "$PHOTOSPHERE_VAULT_DIR" "$PHOTOSPHERE_CONFIG_DIR"

    local db_path="$test_dir/db"

    # --- 1. The database list is a file of its own. ---

    invoke_command "Add a database" "$(get_cli_command) dbs add --yes --name config-file-db --path $db_path" 0

    expect_config_file "databases.toml" "The database list is written to its own databases.toml"

    # --- 2. Settings go to config.yaml, and the files it replaced are not written. ---

    # `news` is what makes the CLI write settings: it records the items it has shown so the next run,
    # and the desktop app on the same machine, do not show them again. That state used to be a
    # news.yaml of its own; it is a section of the config file now.
    local news_output
    invoke_command "Run the news command" "$(get_cli_command) news" 0 "news_output"

    expect_config_file "config.yaml" "The settings are written to config.yaml"

    expect_no_config_file "desktop.toml" "No desktop.toml is written"
    expect_no_config_file "auto-import.toml" "No auto-import.toml is written"
    expect_no_config_file "sync.toml" "No sync.toml is written"
    expect_no_config_file "news.yaml" "No news.yaml is written"

    # --- 3. The two files hold different things and neither holds the other's. ---

    local config_contents
    config_contents="$(cat "$PHOTOSPHERE_CONFIG_DIR/config.yaml")"
    expect_output_string "$config_contents" "news:" "config.yaml has a news section"

    local databases_contents
    databases_contents="$(cat "$PHOTOSPHERE_CONFIG_DIR/databases.toml")"
    expect_output_string "$databases_contents" "config-file-db" "databases.toml holds the database that was added"
    expect_output_string "$config_contents" "config-file-db" "config.yaml does not hold the database list" false
    expect_output_string "$databases_contents" "news" "databases.toml does not hold the news state" false

    export PHOTOSPHERE_VAULT_DIR="$saved_vault"
    export PHOTOSPHERE_CONFIG_DIR="$saved_config"

    test_passed
}

test_config_file "${1:-88}"
