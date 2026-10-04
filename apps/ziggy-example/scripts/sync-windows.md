# sync-windows.sh

Builds the example's page (`bun run bundle:ui`) and the Windows shell (`zig build`), and installs everything the app needs into one directory, `<prefix>/ziggy-example`: `ziggy-example.exe`, `WebView2Loader.dll` beside it, and the page in `ui`. Run `setup-windows.sh` first.

Run it as `bash apps/ziggy-example/scripts/sync-windows.sh [options]`. It works under Git Bash on Windows and cross builds from Linux.

Options:

- `--arch <x64|arm64>`: the architecture to build for. Default `x64`.
- `--prefix <dir>`: the install prefix. Default `apps/ziggy-example/shells/windows/zig-out`.
- `--optimize <Debug|ReleaseSafe|ReleaseFast|ReleaseSmall>`: the Zig optimize mode. Default `Debug`.
- `--test-hooks`: builds the test control connection in. Never use it for something that ships.
