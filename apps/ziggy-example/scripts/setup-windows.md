# setup-windows.sh

One time setup for building the Windows shell. It runs `fetch-webview2.sh`, so see [fetch-webview2.md](fetch-webview2.md) for what it downloads.

It is run on Windows by `bun run --filter=ziggy-example setup` from the repository root, through [setup.sh](setup.md). It takes no arguments. It needs `curl`, `sha256sum` and `unzip` (or the Windows `tar`), and expects `bun install` and `mise install` to have been done.

Building the Windows app also needs Microsoft's C++ toolchain and the Windows SDK, which Visual Studio or its Build Tools install (the "Desktop development with C++" workload). The WebView2 loader is linked into the exe from the SDK's static library, which is built with that toolchain, so Zig must target `x86_64-windows-msvc` to link it, and it finds the toolchain on its own. There is no other way to get a single executable with no DLL beside it.
