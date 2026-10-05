# clean-macos

Runs `xcodebuild clean` for the Debug and Release configurations and removes the synced `lib/libziggy_example.a` and `include/ziggy.h`, and the files of the packages in `out/macos`, one at a time.

Run it on a Mac: `bash apps/ziggy-example/scripts/clean-macos.sh`.

## Arguments

- `--native-dir <dir>`: default: `shells/macos/zig-out`.
- `--build-dir <dir>`: Xcode's derived data directory. Default: `shells/macos/zig-out/xcode`.
