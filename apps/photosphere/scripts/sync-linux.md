# sync-linux.sh

Builds Photosphere's page (`bun run bundle:ui`) and its Linux native app (the `photosphere-linux` step of the root `build.zig`, installed to `native/linux/zig-out` or the prefix given). The native app's build embeds every file of the built page in the executable, so `<prefix>/bin/photosphere` is the whole app and needs no files beside it. Runs on Linux.

## Usage

`bun run --filter=ziggy sync:linux -- [--prefix <dir>] [--optimize <mode>] [--minify] [--strip]`

Run it through the root `package.json` script, not directly.

## Arguments

- `--prefix <dir>`: the install prefix; the executable goes to `<dir>/bin/photosphere`. Give an absolute path, because the script runs `zig build` from the repository root. Default `native/linux/zig-out`. The smoke tests and CI build into a directory of their own with it.
- `--optimize <Debug|ReleaseSafe|ReleaseFast|ReleaseSmall>`: the Zig optimize mode. Default `ReleaseSafe`.
- `--minify`: minifies the page, as the release does.
- `--strip`: strips debug symbols from the executable, as the release does.
