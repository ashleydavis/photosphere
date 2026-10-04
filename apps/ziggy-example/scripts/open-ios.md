# open-ios

Runs `sync-ios.sh`, then opens `shells/ios/ZiggyExample.xcodeproj` in Xcode.

Run it on a Mac: `mise exec -- bash apps/ziggy-example/scripts/open-ios.sh`.

## Arguments

Every argument goes to `sync-ios.sh` (`--sdk`, `--arch`, `--native-dir`, `--test-hooks`, `--optimize`). Sync for the SDK you will build in Xcode (simulator or device), and when you change `--native-dir` set the `ZIGGY_NATIVE_DIR` build setting to match.
