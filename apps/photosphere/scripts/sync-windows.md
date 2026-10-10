# sync-windows.sh

Builds Photosphere's page (`bun run bundle:ui`) and the Windows shell (the `photosphere-windows` step of the root `build.zig`), and installs everything the app needs into one directory, `<prefix>/photosphere`: `photosphere.exe`, which is the whole app. Run `bun run --filter=ziggy setup` from the repository root first. It stops with a message saying what to do when `bun` or `zig` is not on PATH, when on Windows Microsoft's C++ toolchain or the Windows SDK is not installed, or when the WebView2 SDK has not been fetched.

Run it as `bun run --filter=ziggy sync:windows -- [options]`. It works under Git Bash on Windows. From Linux, `zig build photosphere-windows-check -Dtarget=x86_64-windows-gnu -Dcompile-only=true` from the repository root checks that the shell compiles, once `fetch-webview2.sh` has fetched the SDK.

Options:

- `--arch <x64>`: the architecture to build for. Default `x64`. `arm64` is refused, see `package-windows.md`.
- `--prefix <dir>`: the install prefix. Default `apps/photosphere/shells/windows/zig-out`.
- `--optimize <Debug|ReleaseSafe|ReleaseFast|ReleaseSmall>`: the Zig optimize mode. Default `ReleaseSafe`.
- `--test-hooks`: builds the test control connection in. Never use it for something that ships.
