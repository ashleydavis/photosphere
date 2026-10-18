# bundle-core.sh

Runs `zig build photosphere-backend` from the root of the repository for one target, which builds Photosphere's core as a library (`libphotosphere.a`, with `ziggy.h` beside it). Invoked as `bun run --filter=ziggy bundle:core -- <target>`. The page must already be built (`bundle-ui.sh`), because the core embeds it.

## Arguments

- `<target>`: required. The Zig target triple to build for, for example `x86_64-linux-gnu` or `aarch64-macos.11.0`.
- `--test-hooks`: optional. Builds the test hooks in (the test mode switch, the control connection and the other test-only features). Used by the test and stories scripts. Without it, as for every packaged artifact, the build contains none of them.
- `--optimize <Debug|ReleaseSafe|ReleaseFast|ReleaseSmall>`: optional. The Zig optimize mode. Default `ReleaseSafe`.
- `--prefix <dir>`: optional. The install prefix. Without it the root build's own `zig-out` is used.

Runs on Linux, Windows and MacOS for every target except the MacOS and iOS ones. Those two need the macOS SDK, so they build on a Mac only. The Android library is built by `sync-android.sh`, which also gives Zig the NDK's C library.
