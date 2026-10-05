# sync-linux.sh

Builds the example's page (`bun run bundle:ui`) and its Linux shell (`zig build` in `shells/linux`). The shell's build embeds every file of the built page in the executable, so `shells/linux/zig-out/bin/ziggy-example` is the whole app and needs no files beside it. Runs on Linux.

## Usage

`bash apps/ziggy-example/scripts/sync-linux.sh [--optimize <mode>] [--test-hooks]`

Run it through the root `package.json` script, not directly.

## Arguments

- `--optimize <Debug|ReleaseSafe|ReleaseFast|ReleaseSmall>`: the Zig optimize mode. Default `ReleaseSafe`.
- `--test-hooks`: builds the test hooks into the app (the test control connection). Off by default, and never used for `package-linux.sh`.
