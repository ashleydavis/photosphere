# sync-ios

Puts what the iOS Xcode project needs into a native directory: `lib/libziggy_example.a` and `include/ziggy.h` (built with Zig for iOS 14.0, the simulator or the device) and `ui/` (the example's page).

Run it on a Mac, through mise: `mise exec -- bash apps/ziggy-example/scripts/sync-ios.sh`.

## Arguments

- `--sdk <simulator|device>`: default: `simulator`. A device build is arm64 only.
- `--arch <arm64|x86_64>`: default: this Mac's (the simulator runs the Mac's architecture).
- `--native-dir <dir>`: default: `shells/ios/zig-out`. The library there is for one SDK and architecture, so sync again after changing either.
- `--test-hooks`: build the library with the test control connection. Never use it for a release.
- `--optimize <mode>`: default: `ReleaseSafe`.
