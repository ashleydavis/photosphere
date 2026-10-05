# windows-common.sh

Paths and helpers shared by the Windows scripts in this directory. It is sourced, never run: `source windows-common.sh`.

It sets `WINDOWS_EXAMPLE_DIR`, `WINDOWS_SHELL_DIR`, `WINDOWS_SDK_DIR` and `WINDOWS_APP_DIR_NAME`, as Windows style paths under Git Bash (`pwd -W`, the same way `apps/cli/smoke-tests-zig.sh` does it) so that `zig.exe` can resolve them. It also defines `windows_zig_target <x64>` (the `-windows-msvc` target, which links the WebView2 loader statically and so needs Visual Studio's C++ tools), `windows_app_version` (from `package.json`, with `jq`), `windows_unzip <zip> <dir>` and `windows_zip <zip> <parent> <name>`. Git Bash has no `unzip`, so on Windows these fall back to the `tar.exe` that ships with Windows.

`windows_require_commands <command>...` stops the script, naming what is missing and how to put mise's tools on PATH, when any of the commands is not on PATH.

`windows_msvc_toolchain_installed` succeeds when `vswhere` finds a Visual Studio or Build Tools instance with the x64 C++ tools and the registry has the Windows SDK root (`KitsRoot10`), which is what Zig needs for the `-windows-msvc` target. `windows_require_msvc_toolchain` stops the script, saying to run setup, when they are missing on a Windows host, and does nothing on any other host. `windows_require_wix` stops the script, saying to run setup, when the pinned WiX Toolset is not in `WINDOWS_WIX_DIR` (`wix/wix-<WIX_VERSION>`). `fetch_verified <url> <file> <sha256>` downloads a file unless it is already there, and fails when its sha256 is not the pinned one.

It takes no arguments.
