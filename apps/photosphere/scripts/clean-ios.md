# clean-ios

Runs `xcodebuild clean` for the Debug and Release configurations and removes the synced `lib/libphotosphere.a` and `include/ziggy.h`, and the files of the packages in `out/ios`, one at a time.

Run it on a Mac: `bun run --filter=ziggy clean:ios`.

## Arguments

- `--native-dir <dir>`: default: `shells/ios/zig-out`.
- `--build-dir <dir>`: default: `shells/ios/zig-out/xcode`.
