# clean-ios

Runs `xcodebuild clean` for the Debug and Release configurations and removes the synced `lib/libziggy_example.a` and `include/ziggy.h`. The synced `ui/` copy stays until the next sync overwrites it.

Run it on a Mac: `bash apps/ziggy-example/scripts/clean-ios.sh`.

## Arguments

- `--native-dir <dir>`: default: `shells/ios/zig-out`.
- `--build-dir <dir>`: default: `shells/ios/zig-out/xcode`.
