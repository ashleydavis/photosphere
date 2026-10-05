# sync-windows.sh

Builds the example's page (`bun run bundle:ui`) and the Windows shell (`zig build`), and installs everything the app needs into one directory, `<prefix>/ziggy-example`: `ziggy-example.exe`, which is the whole app. Run `bun run --filter=ziggy-example setup` from the repository root first. It stops with a message saying what to do when `bun` or `zig` is not on PATH, or the WebView2 SDK has not been fetched.

Run it as `bash apps/ziggy-example/scripts/sync-windows.sh [options]`. It works under Git Bash on Windows and cross builds from Linux.

Options:

- `--arch <x64>`: the architecture to build for. Default `x64`. `arm64` is refused, see `package-windows.md`.
- `--prefix <dir>`: the install prefix. Default `apps/ziggy-example/shells/windows/zig-out`.
- `--optimize <Debug|ReleaseSafe|ReleaseFast|ReleaseSmall>`: the Zig optimize mode. Default `Debug`.
- `--test-hooks`: builds the test control connection in. Never use it for something that ships.
