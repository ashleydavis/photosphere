# sync-ios

Builds Photosphere's page (`bun run bundle:ui`) and puts what the iOS Xcode project needs into a native directory: `lib/libphotosphere.a` and `include/ziggy.h` (built with Zig for iOS 14.0, the simulator or the device). The page is embedded in the library, so the app has no page files of its own. Before the library is built, any ImageMagick or FFmpeg file the target needs that is missing is made (see `apple-common.md`), so a Mac needs no manual step for the in-process media libraries; those libraries are linked into `libphotosphere.a` and the Xcode project links nothing else for them.

Run it on a Mac: `bun run --filter=ziggy sync:ios`.

## Arguments

- `--sdk <simulator|device>`: default: `simulator`. A device build is arm64 only.
- `--arch <arm64|x86_64>`: default: this Mac's (the simulator runs the Mac's architecture).
- `--native-dir <dir>`: default: `native/ios/zig-out`. The library there is for one SDK and architecture, so sync again after changing either.
- `--minify`: minify the page, for a release package.
- `--test-hooks`: build the library with the test control connection. Never use it for a release.
- `--optimize <mode>`: default: `ReleaseSafe`.
