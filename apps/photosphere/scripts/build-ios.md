# build-ios

Runs `sync-ios.sh`, then `xcodebuild` on `native/ios/Photosphere.xcodeproj`, with code signing off for the simulator and automatic signing by the Xcode account's team (or `PHOTOSPHERE_IOS_TEAM`) for a device, producing `<build-dir>/Build/Products/<configuration>-iphonesimulator/Photosphere.app` (or `-iphoneos`).

Run it on a Mac with Xcode: `bun run --filter=ziggy build:ios`.

## Arguments

- `--sdk <simulator|device>`: default: `simulator`.
- `--arch <arm64|x86_64>`: default: this Mac's.
- `--native-dir <dir>`: default: `native/ios/zig-out`.
- `--build-dir <dir>`: default: `native/ios/zig-out/xcode`.
- `--configuration <Debug|Release>`: default: `Debug`.
- `--test-hooks`: build with the test control connection.
- `--optimize <mode>`: default: `ReleaseSafe`.
