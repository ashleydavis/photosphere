# build-ios

Runs `sync-ios.sh`, then `xcodebuild` on `shells/ios/ZiggyExample.xcodeproj` with code signing off, producing `<build-dir>/Build/Products/<configuration>-iphonesimulator/ZiggyExample.app` (or `-iphoneos`).

Run it on a Mac with Xcode: `mise exec -- bash apps/ziggy-example/scripts/build-ios.sh`.

## Arguments

- `--sdk <simulator|device>`: default: `simulator`.
- `--arch <arm64|x86_64>`: default: this Mac's.
- `--native-dir <dir>`: default: `shells/ios/zig-out`.
- `--build-dir <dir>`: default: `shells/ios/zig-out/xcode`.
- `--configuration <Debug|Release>`: default: `Debug`.
- `--test-hooks`: build with the test control connection.
- `--optimize <mode>`: default: `ReleaseSafe`.
