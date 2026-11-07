# open-ios

Runs `sync-ios.sh`, then opens `native/ios/Photosphere.xcodeproj` in Xcode.

Run it on a Mac: `bun run --filter=ziggy open:ios`.

## Arguments

Every argument goes to `sync-ios.sh` (`--sdk`, `--arch`, `--native-dir`, `--optimize`). Sync for the SDK you will build in Xcode (simulator or device), and when you change `--native-dir` set the `ZIGGY_NATIVE_DIR` build setting to match.
