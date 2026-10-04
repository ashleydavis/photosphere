# bundle-core.sh

Runs `zig build` in `packages-zig/photosphere-core` for one target. Invoked as `bun run --filter=ziggy bundle:core -- <target>`.

## Arguments

- `--test-hooks`: optional. Builds the test hooks in (the test mode switch, the control connection and the other test-only features). Used by the test and stories scripts. Without it, as for every packaged artifact, the build contains none of them.
- `<target>`: the Zig target triple to build for (for example `x86_64-linux-gnu`, `x86_64-windows-gnu`, `aarch64-linux-android`).

Runs on Linux, Windows and MacOS for every target except the MacOS and iOS ones. Those two need the macOS SDK, so they build on a Mac only.
