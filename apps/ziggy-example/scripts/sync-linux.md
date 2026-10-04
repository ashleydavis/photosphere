# sync-linux.sh

Builds the example's page (`bun run bundle:ui`) and its Linux shell (`zig build` in `shells/linux`), then copies the built page into `shells/linux/zig-out/bin/ui`, where the executable looks for it. Runs on Linux.

## Usage

`bash apps/ziggy-example/scripts/sync-linux.sh [--test-hooks]`

Run it through the root `package.json` script, not directly.

## Arguments

- `--test-hooks`: builds the test hooks into the app (the test control connection). Off by default, and never used for `package-linux.sh`.
