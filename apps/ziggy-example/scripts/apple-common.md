# apple-common

`lib/apple-common.sh` is the shell library the MacOS and iOS scripts source. It is never run. It holds the checks (`apple_require_macos`, `apple_require_tool`, `apple_require_xcode`), the version and architecture helpers, `apple_sync_native` (bundle the page, build the Zig static library, copy the page into the native directory) and `apple_pick_simulator` (choose and boot an existing iOS simulator, never creating or deleting one).

It is sourced from the script's own directory: `source "$SCRIPT_DIR/lib/apple-common.sh"`. It takes no arguments of its own. `ZIGGY_IOS_SIMULATOR` (a simulator name or identifier) selects the simulator `apple_pick_simulator` uses.
