#!/bin/bash
DESCRIPTION="What the app remembered goes in state.json, the database list stays in its own databases.toml, and none of the files they replaced comes back"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

# The settings live in two files now, split by who decided them: config.toml holds what the user
# chose and state.json holds what the app remembered. Before either there were four files, in two
# formats, and which one a setting landed in depended on which platform had written it.
#
# This test is about the files themselves: that the news state the CLI records goes to state.json
# rather than a news.yaml of its own, that the CLI writes no config.toml at all because it reads none
# of the settings, that databases.toml stays the separate file it was always meant to be, and that
# `psi version` names the two files.
#
# It runs with PHOTOSPHERE_CONFIG_DIR and PHOTOSPHERE_STATE_DIR pointed at directories of its own, so
# it reads and writes the settings of nothing but itself. Without that it would be looking at the
# settings of whoever is running it, and every assertion below would depend on what they happen to
# have configured.

#
# Fails the test unless the named file is in the named directory.
#
expect_file_in() {
    local directory="$1"
    local file_name="$2"
    local description="$3"

    if [ -f "$directory/$file_name" ]; then
        log_success "$description"
        return 0
    fi

    log_error "$description ($file_name is not in $directory)"
    ls -la "$directory" 2>/dev/null || true
    exit 1
}

#
# Fails the test when the named file is in the named directory.
#
expect_no_file_in() {
    local directory="$1"
    local file_name="$2"
    local description="$3"

    if [ ! -f "$directory/$file_name" ]; then
        log_success "$description"
        return 0
    fi

    log_error "$description ($file_name is in $directory and should not be)"
    cat "$directory/$file_name"
    exit 1
}

test_config_file() {
    local test_number="$1"
    print_test_header "$test_number" "CONFIG FILE"

    local saved_vault="$PHOTOSPHERE_VAULT_DIR"
    local saved_config="$PHOTOSPHERE_CONFIG_DIR"
    local saved_state="$PHOTOSPHERE_STATE_DIR"
    local test_dir="$TEST_TMP_DIR/config-file"
    export PHOTOSPHERE_VAULT_DIR="$test_dir/vault"
    export PHOTOSPHERE_CONFIG_DIR="$test_dir/config"
    export PHOTOSPHERE_STATE_DIR="$test_dir/state"
    mkdir -p "$PHOTOSPHERE_VAULT_DIR" "$PHOTOSPHERE_CONFIG_DIR" "$PHOTOSPHERE_STATE_DIR"

    local db_path="$test_dir/db"

    # --- 1. The database list is a file of its own. ---

    invoke_command "Add a database" "$(get_zig_cli_command) dbs add --yes --name config-file-db --path $db_path" 0

    expect_file_in "$PHOTOSPHERE_CONFIG_DIR" "databases.toml" "The database list is written to its own databases.toml"

    # --- 2. The news state goes to state.json, and the files it replaced are not written. ---

    # `news` is what makes the CLI write anything but the database list: it records the items it has
    # shown so the next run, and the desktop app on the same machine, do not show them again. That
    # used to have a file of its own, then a section of the settings file; it is in state.json now,
    # because nobody chose it and it is not worth carrying anywhere.
    #
    # It reads the checked-in test/demo-news.yaml through a file:// URL (PHOTOSPHERE_NEWS_URL), so
    # there are items to record without a network: the published feed may be out of reach, and a feed
    # that cannot be read records nothing.
    local news_dir
    news_dir="$(cd "$TEST_FILES_DIR" && (pwd -W 2> /dev/null || pwd))"
    local news_url="file://$news_dir/demo-news.yaml"
    if [[ "$news_dir" != /* ]]; then
        news_url="file:///$news_dir/demo-news.yaml"
    fi
    local news_output
    invoke_command "Run the news command" "PHOTOSPHERE_NEWS_URL=\"$news_url\" $(get_zig_cli_command) news" 0 "news_output"

    expect_file_in "$PHOTOSPHERE_STATE_DIR" "state.json" "What the app remembered is written to state.json"

    # The CLI takes its instructions from the command line and reads none of the settings, so it must
    # never bring the settings file into being. A file there would tell a desktop app on the same
    # machine that settings had been chosen when nobody had chosen any.
    expect_no_file_in "$PHOTOSPHERE_CONFIG_DIR" "config.toml" "No config.toml is written, because the CLI has no settings to write"

    expect_no_file_in "$PHOTOSPHERE_CONFIG_DIR" "desktop.toml" "No desktop.toml is written"
    expect_no_file_in "$PHOTOSPHERE_CONFIG_DIR" "auto-import.toml" "No auto-import.toml is written"
    expect_no_file_in "$PHOTOSPHERE_CONFIG_DIR" "sync.toml" "No sync.toml is written"
    expect_no_file_in "$PHOTOSPHERE_CONFIG_DIR" "news.yaml" "No news.yaml is written"

    # The old file names are built here rather than written out, because the repository keeps no
    # mention of them outside the plans.
    local old_format="yaml"
    expect_no_file_in "$PHOTOSPHERE_CONFIG_DIR" "config.$old_format" "The old settings file does not come back"
    expect_no_file_in "$PHOTOSPHERE_STATE_DIR" "state.$old_format" "The old state file does not come back"

    # --- 3. The two files hold different things and neither holds the other's. ---

    local state_contents
    state_contents="$(cat "$PHOTOSPHERE_STATE_DIR/state.json")"
    expect_output_string "$state_contents" "news" "state.json has a news section"

    local databases_contents
    databases_contents="$(cat "$PHOTOSPHERE_CONFIG_DIR/databases.toml")"
    expect_output_string "$databases_contents" "config-file-db" "databases.toml holds the database that was added"
    expect_output_string "$state_contents" "config-file-db" "state.json does not hold the database list" false
    expect_output_string "$databases_contents" "news" "databases.toml does not hold the news state" false

    # --- 4. The version command names the two files. ---

    local version_output
    invoke_command "Run the version command" "$(get_zig_cli_command) version" 0 "version_output"
    expect_output_string "$version_output" "$PHOTOSPHERE_CONFIG_DIR/config.toml" "psi version names the config file"
    expect_output_string "$version_output" "$PHOTOSPHERE_STATE_DIR/state.json" "psi version names the state file"

    export PHOTOSPHERE_VAULT_DIR="$saved_vault"
    export PHOTOSPHERE_CONFIG_DIR="$saved_config"
    export PHOTOSPHERE_STATE_DIR="$saved_state"

    test_passed
}

test_config_file "${1:-88}"
