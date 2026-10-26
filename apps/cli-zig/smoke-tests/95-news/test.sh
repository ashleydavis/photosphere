#!/bin/bash
DESCRIPTION="psi news shows the whole feed newest first, marks what it showed as seen, and reads back what it recorded"

# The feed is the checked-in test/demo-news.yaml, read through a file:// URL (PHOTOSPHERE_NEWS_URL,
# the override the demo scripts use), so the test needs no network and knows exactly what the feed
# holds. The CLI records what it has shown in state.yaml under a config directory of its own for each
# part here, and every news output and the recorded state are compared in full with the expected
# text. The running version in that text is read from the CLI's config.zig, which is what the CLI
# under test was built from, whether that is the checked-in "dev" or a version a release stamped in.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
trap cleanup_and_show_summary EXIT

#
# Prints one item of the news as `psi news` shows it: starred and marked new, or bulleted when it was
# already shown, with each of its detail lines indented under it.
# Usage: expected_news_item <1 when new, 0 when shown> <message> [detail line...]
#
expected_news_item() {
    local is_new="$1"
    local message="$2"
    shift 2

    if [ "$is_new" -eq 1 ]; then
        printf '\n★ %s (new)' "$message"
    else
        printf '\n• %s' "$message"
    fi

    local detail_line
    for detail_line in "$@"; do
        printf '\n     %s' "$detail_line"
    done
}

#
# Prints the whole of what `psi news` shows for the demo feed, newest first, with the given number of
# the newest items still new and the rest already shown.
# Usage: expected_news <running version> <number of items still new>
#
expected_news() {
    local running_version="$1"
    local new_items="$2"

    printf '\n📋 Photosphere News\n\nRunning version: v%s\n' "$running_version"
    expected_news_item "$((new_items >= 1))" "Heads up: scheduled maintenance window this weekend (no link, no button)."
    expected_news_item "$((new_items >= 2))" "Photosphere v1.5 is out: much faster sync and a redesigned navbar." \
        "Release notes: https://example.com/photosphere/releases/v1.5" \
        "Upgrade now: https://example.com/photosphere/download"
    expected_news_item "$((new_items >= 3))" "New blog post: how Photosphere stores your photos end-to-end encrypted." \
        "Read the post: https://example.com/photosphere/blog/e2ee"
    expected_news_item "$((new_items >= 4))" "We'd love your feedback. Take our 2-minute user survey!" \
        "Open the survey: https://example.com/photosphere/survey"
    expected_news_item "$((new_items >= 5))" "Welcome to Photosphere. Thanks for trying it out!" \
        "Read the docs: https://github.com/ashleydavis/photosphere/wiki" \
        "What's new: https://github.com/ashleydavis/photosphere/releases/latest"
}

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
    mkdir -p "$zig_config"

    export PHOTOSPHERE_NEWS_URL
    PHOTOSPHERE_NEWS_URL="$(file_url "$TEST_FILES_DIR/demo-news.yaml")"
    log_info "News feed: $PHOTOSPHERE_NEWS_URL"

    local running_version
    running_version="$(sed -n 's/^pub const version = "\(.*\)";$/\1/p' "$SCRIPT_DIR/../../src/lib/config.zig")"
    log_info "Running version: $running_version"

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

    expect_value "$first_output" "$(expected_news "$running_version" 5)" "The whole of the news is shown, every item new"

    local expected_state
    expected_state="$(printf '%s\n' \
        "news:" \
        "  shown_news_ids:" \
        "    - demo-001-welcome" \
        "    - demo-002-survey" \
        "    - demo-003-blog" \
        "    - demo-004-release" \
        "    - demo-005-bare")"
    expect_value "$zig_state" "$expected_state" "The whole of the recorded state is as expected"

    # --- 2. The second run shows every item as seen. ---

    local second_output
    invoke_command "Show the news again with the Zig CLI" "PHOTOSPHERE_CONFIG_DIR=\"$zig_config\" $(get_zig_cli_command) news" 0 "second_output"
    expect_output_string "$second_output" "(new)" "No item is new the second time" false
    expect_output_string "$second_output" "Welcome to Photosphere. Thanks for trying it out!$" "The seen items are still listed"

    expect_value "$second_output" "$(expected_news "$running_version" 0)" "The whole of the news is shown, every item read back as shown"

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
    invoke_command "Show the news with the Zig CLI after those notifications" "PHOTOSPHERE_CONFIG_DIR=\"$notify_config\" $(get_zig_cli_command) news" 0 "after_notify_output"
    expect_output_string "$after_notify_output" "Welcome to Photosphere. Thanks for trying it out!$" "The news command knows the first item was shown"
    expect_output_string "$after_notify_output" "Take our 2-minute user survey!$" "The news command knows the second item was shown"
    expect_output_string "$after_notify_output" "end-to-end encrypted. (new)" "The news command still shows the third item as new"
    expect_value "$after_notify_output" "$(expected_news "$running_version" 3)" "The whole of the news is shown, the two notified items as shown"

    # --- 4. A feed that cannot be read. ---

    local empty_config="$test_dir/empty-config"
    mkdir -p "$empty_config"
    local missing_feed_url
    missing_feed_url="$(file_url "$test_dir/no-such-feed.yaml")"

    local missing_output
    invoke_command "Show the news of a feed that is not there with the Zig CLI" "PHOTOSPHERE_NEWS_URL=\"$missing_feed_url\" PHOTOSPHERE_CONFIG_DIR=\"$empty_config\" $(get_zig_cli_command) news" 0 "missing_output"
    expect_output_string "$missing_output" "^No news items available.$" "An unreadable feed shows no items"

    expect_value "$missing_output" "$(printf '\n📋 Photosphere News\n\nRunning version: v%s\n\nNo news items available.' "$running_version")" "The whole report of an unreadable feed is as expected"

    test_passed
}

test_news "${1:-95}"
