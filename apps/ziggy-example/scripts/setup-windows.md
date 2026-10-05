# setup-windows.sh

One time setup for building and packaging the Windows shell. It first runs `fetch-webview2.sh` (see [fetch-webview2.md](fetch-webview2.md) for what that downloads), which needs no administrator approval, then `fetch-wix.sh`, and then installs what is missing.

It is run on Windows by `bun run --filter=ziggy-example setup` from the repository root, through [setup.sh](setup.md), and by the root `bun run setup`. It takes no arguments. It needs `curl`, `sha256sum` and `unzip` (or the Windows `tar`), and expects `bun install` and `mise install` to have been done.

Building the Windows app needs Microsoft's C++ toolchain and the Windows SDK. The WebView2 loader is linked into the exe from the SDK's static library, which is built with that toolchain, so Zig must target `x86_64-windows-msvc` to link it, and it finds the toolchain on its own. There is no other way to get a single executable with no DLL beside it. When `vswhere` finds no Visual Studio or Build Tools instance with the x64 C++ tools, or the registry has no Windows SDK root, the script installs Visual Studio 2022 Build Tools with the "Desktop development with C++" workload (`Microsoft.VisualStudio.Workload.VCTools` and its recommended components, which include the Windows SDK) through `winget`.

Packaging needs the WiX Toolset. The script runs `fetch-wix.sh` (see [fetch-wix.md](fetch-wix.md)), which downloads a pinned copy into the example and needs no administrator approval.

The Build Tools install is machine wide, so Windows asks for administrator approval. When they are already installed the script leaves them alone. After installing, it checks again and stops with a message when the check still fails, which happens when Visual Studio or its Build Tools were already installed without the C++ workload, because `winget` does not modify an existing install: add the workload in the Visual Studio Installer. It also stops when `winget` is needed and is not on PATH.
