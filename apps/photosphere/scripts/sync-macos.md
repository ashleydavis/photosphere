# sync-macos

Builds Photosphere's page (`bun run bundle:ui`) and puts what the MacOS Xcode project needs into a native directory: `lib/libphotosphere.a` and `include/ziggy.h` (built with Zig for the macOS target, deployment target 11.0). The page is embedded in the library, so the app has no page files of its own.

Run it on a Mac: `bun run --filter=ziggy sync:macos`.

## Arguments

- `--arch <arm64|x86_64>`: the architecture to build. Default: this Mac's.
- `--native-dir <dir>`: where to put the files. Default: `native/macos/zig-out`.
- `--minify`: minify the page, for a release package.
- `--optimize <mode>`: the Zig optimize mode. Default: `ReleaseSafe`.
