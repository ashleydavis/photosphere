# sync-linux.sh

Builds Photosphere's page (`bun run bundle:ui`) and its Linux shell (the `photosphere-linux` step of the root `build.zig`, installed to `native/linux/zig-out`). The shell's build embeds every file of the built page in the executable, so `native/linux/zig-out/bin/photosphere` is the whole app and needs no files beside it. Runs on Linux.

## Usage

`bun run --filter=ziggy sync:linux -- [--optimize <mode>] [--test-hooks]`

Run it through the root `package.json` script, not directly.

## Arguments

- `--optimize <Debug|ReleaseSafe|ReleaseFast|ReleaseSmall>`: the Zig optimize mode. Default `ReleaseSafe`.
- `--test-hooks`: builds the test hooks into the app (the test control connection). Off by default, and never used for `package-linux.sh`.
