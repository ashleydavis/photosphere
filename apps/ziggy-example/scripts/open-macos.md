# open-macos

Runs `sync-macos.sh`, then opens `shells/macos/ZiggyExample.xcodeproj` in Xcode, so a build from Xcode finds the library and the page.

Run it on a Mac: `mise exec -- bash apps/ziggy-example/scripts/open-macos.sh`.

## Arguments

Every argument goes to `sync-macos.sh` (`--arch`, `--native-dir`, `--test-hooks`, `--optimize`). When you change `--native-dir`, set the `ZIGGY_NATIVE_DIR` build setting in Xcode to the same directory.
