# windows-common.sh

Paths and helpers shared by the Windows scripts in this directory. It is sourced, never run: `source windows-common.sh`.

It sets `WINDOWS_EXAMPLE_DIR`, `WINDOWS_SHELL_DIR`, `WINDOWS_SDK_DIR` and `WINDOWS_APP_DIR_NAME`, as Windows style paths under Git Bash (`pwd -W`, the same way `apps/cli/smoke-tests-zig.sh` does it) so that `zig.exe` can resolve them. It also defines `windows_zig_target <x64>` (the `-windows-msvc` target, which links the WebView2 loader statically and so needs Visual Studio's C++ tools), `windows_app_version` (from `package.json`, with `jq`), `windows_unzip <zip> <dir>` and `windows_zip <zip> <parent> <name>`. Git Bash has no `unzip`, so on Windows these fall back to the `tar.exe` that ships with Windows.

`windows_require_commands <command>...` stops the script, naming what is missing and how to put mise's tools on PATH, when any of the commands is not on PATH.

It takes no arguments.
