# sync-macos

Builds the example's page (`bun run bundle:ui`) and puts what the MacOS Xcode project needs into a native directory: `lib/libziggy_example.a` and `include/ziggy.h` (built with Zig for the macOS target, deployment target 11.0). The page is embedded in the library, so the app has no page files of its own.

Run it on a Mac, through mise so the pinned Zig and Bun are used: `mise exec -- bash apps/ziggy-example/scripts/sync-macos.sh`.

## Arguments

- `--arch <arm64|x86_64>`: the architecture to build. Default: this Mac's.
- `--native-dir <dir>`: where to put the files. Default: `shells/macos/zig-out`.
- `--test-hooks`: build the library with the test control connection. Never use it for a release.
- `--optimize <mode>`: the Zig optimize mode. Default: `ReleaseSafe`.
