#!/bin/bash
DESCRIPTION="psi news shows the whole feed newest first, marks what it showed as seen, and the TypeScript CLI reads what it recorded"

# The feed is the checked-in test/demo-news.yaml, read through a file:// URL (PHOTOSPHERE_NEWS_URL,
# the override the demo scripts use), so the test needs no network and knows exactly what the feed
# holds. Each CLI records what it has shown in state.yaml under a config directory of its own here,
# so the two can be run from the same starting point and what they record compared byte for byte.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

#
# Prints the file:// URL of a file, with the drive letter form on Windows.
#
file_url() {
    local file_path="$1"

    local directory
    directory="$(cd "$(dirname "$file_path")" && (pwd -W 2> /dev/null || pwd))"
    local absolute_path="$directory/$(basename "$file_path")"
    if [[ "$absolute_path" == /* ]]; then
        echo "file://$absolute_path"
    else
        echo "file:///$absolute_path"
    fi
}

test_news() {
    local test_number="$1"
    print_test_header "$test_number" "NEWS"

    local test_dir
    test_dir="$(get_test_dir "$test_number")"
    local zig_config="$test_dir/zig-config"
    local ts_config="$test_dir/ts-config"
    mkdir -p "$zig_config" "$ts_config"

    export PHOTOSPHERE_NEWS_URL
    PHOTOSPHERE_NEWS_URL="$(file_url "$TEST_FILES_DIR/demo-news.yaml")"
    log_info "News feed: $PHOTOSPHERE_NEWS_URL"

    # --- 1. The first run shows every item as new, newest first. ---

    local first_output
    invoke_command "Show the news with the Zig CLI" "PHOTOSPHERE_CONFIG_DIR=\"$zig_config\" $(get_zig_cli_command) news" 0 "first_output"

    expect_output_string "$first_output" "Photosphere News" "The news has its heading"
    expect_output_string "$first_output" "^Running version: v" "The news shows the running version"
    expect_output_string "$first_output" "Welcome to Photosphere. Thanks for trying it out! (new)" "The oldest item is shown as new"
    expect_output_string "$first_output" "Heads up: scheduled maintenance window this weekend (no link, no button). (new)" "The newest item is shown as new"
    expect_output_string "$first_output" "^     Release notes: https://example.com/photosphere/releases/v1.5$" "An item's link is shown under it"
    expect_output_string "$first_output" "^     Upgrade now: https://example.com/photosphere/download$" "An item's action is shown under it"

    local item_order
    item_order="$(echo "$first_output" | grep -o "Heads up\|v1.5 is out\|New blog post\|We'd love your feedback\|Welcome to Photosphere" | tr '\n' ',')"
    expect_value "$item_order" "Heads up,v1.5 is out,New blog post,We'd love your feedback,Welcome to Photosphere," "The items are shown newest first"

    check_exists "$zig_config/state.yaml" "The state the news command records"
    local zig_state
    zig_state="$(cat "$zig_config/state.yaml")"
    local item_id
    for item_id in demo-001-welcome demo-002-survey demo-003-blog demo-004-release demo-005-bare; do
        expect_output_string "$zig_state" "^    - $item_id$" "$item_id is recorded as shown"
    done

    local ts_first_output
    invoke_command "Show the news with the TypeScript CLI" "PHOTOSPHERE_CONFIG_DIR=\"$ts_config\" $(get_cli_command) news" 0 "ts_first_output"
    expect_value "$first_output" "$ts_first_output" "The Zig CLI shows the news as the TypeScript CLI does"

    local ts_state
    ts_state="$(cat "$ts_config/state.yaml")"
    expect_value "$zig_state" "$ts_state" "The Zig CLI records the news it showed as the TypeScript CLI does"

    # --- 2. The second run shows every item as seen. ---

    local second_output
    invoke_command "Show the news again with the Zig CLI" "PHOTOSPHERE_CONFIG_DIR=\"$zig_config\" $(get_zig_cli_command) news" 0 "second_output"
    expect_output_string "$second_output" "(new)" "No item is new the second time" false
    expect_output_string "$second_output" "Welcome to Photosphere. Thanks for trying it out!$" "The seen items are still listed"

    local ts_second_output
    invoke_command "Show the news with the TypeScript CLI from what the Zig CLI recorded" "PHOTOSPHERE_CONFIG_DIR=\"$zig_config\" $(get_cli_command) news" 0 "ts_second_output"
    expect_value "$ts_second_output" "$second_output" "The TypeScript CLI reads what the Zig CLI recorded as shown"

    # --- 3. Any other command shows the oldest unseen item once, and the news command then knows it. ---

    local notify_config="$test_dir/notify-config"
    mkdir -p "$notify_config"

    local notify_output
    invoke_command "Run another command with the Zig CLI" "PHOTOSPHERE_CONFIG_DIR=\"$notify_config\" $(get_zig_cli_command) examples" 0 "notify_output"
    expect_output_string "$notify_output" "News:" "The command shows a news item first"
    expect_output_string "$notify_output" "^   Welcome to Photosphere. Thanks for trying it out!$" "The item shown is the oldest one"
    expect_output_string "$notify_output" "user survey" "Only one item is shown" false

    local notify_again_output
    invoke_command "Run it again with the Zig CLI" "PHOTOSPHERE_CONFIG_DIR=\"$notify_config\" $(get_zig_cli_command) examples" 0 "notify_again_output"
    expect_output_string "$notify_again_output" "^   We'd love your feedback. Take our 2-minute user survey!$" "The next run shows the next item"

    local after_notify_output
    invoke_command "Show the news with the TypeScript CLI after those notifications" "PHOTOSPHERE_CONFIG_DIR=\"$notify_config\" $(get_cli_command) news" 0 "after_notify_output"
    expect_output_string "$after_notify_output" "Welcome to Photosphere. Thanks for trying it out!$" "The TypeScript CLI knows the first item was shown"
    expect_output_string "$after_notify_output" "Take our 2-minute user survey!$" "The TypeScript CLI knows the second item was shown"
    expect_output_string "$after_notify_output" "end-to-end encrypted. (new)" "The TypeScript CLI still shows the third item as new"

    # --- 4. A feed that cannot be read. ---

    local empty_config="$test_dir/empty-config"
    mkdir -p "$empty_config"
    local missing_feed_url
    missing_feed_url="$(file_url "$test_dir/no-such-feed.yaml")"

    local missing_output
    invoke_command "Show the news of a feed that is not there with the Zig CLI" "PHOTOSPHERE_NEWS_URL=\"$missing_feed_url\" PHOTOSPHERE_CONFIG_DIR=\"$empty_config\" $(get_zig_cli_command) news" 0 "missing_output"
    expect_output_string "$missing_output" "^No news items available.$" "An unreadable feed shows no items"

    local ts_missing_output
    invoke_command "Show the news of a feed that is not there with the TypeScript CLI" "PHOTOSPHERE_NEWS_URL=\"$missing_feed_url\" PHOTOSPHERE_CONFIG_DIR=\"$empty_config\" $(get_cli_command) news" 0 "ts_missing_output"
    expect_value "$missing_output" "$ts_missing_output" "The Zig CLI reports an unreadable feed as the TypeScript CLI does"

    test_passed
}

test_news "${1:-95}"
