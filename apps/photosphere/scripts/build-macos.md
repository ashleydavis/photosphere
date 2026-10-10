# build-macos

Runs `sync-macos.sh`, then `xcodebuild` on `shells/macos/Photosphere.xcodeproj`, producing `<build-dir>/Build/Products/<configuration>/Photosphere.app`. The app is ad hoc signed.

Run it on a Mac with Xcode: `bun run --filter=ziggy build:macos`.

## Arguments

- `--arch <arm64|x86_64>`: default: this Mac's.
- `--native-dir <dir>`: passed to the sync script and to Xcode as `ZIGGY_NATIVE_DIR`. Default: `shells/macos/zig-out`.
- `--build-dir <dir>`: Xcode's derived data directory. Default: `shells/macos/zig-out/xcode`.
- `--configuration <Debug|Release>`: default: `Debug`.
- `--test-hooks`: build with the test control connection (the smoke tests use this).
- `--optimize <mode>`: the Zig optimize mode. Default: `ReleaseSafe`.
