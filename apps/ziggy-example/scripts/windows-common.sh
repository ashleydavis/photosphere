#!/usr/bin/env bash

# Paths and helpers shared by the Windows scripts. Source it, never run it. See windows-common.md.

WINDOWS_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# On Windows (msys/cygwin), pwd returns a POSIX path (/d/a/...) that native .exe programs such as zig cannot resolve.
# pwd -W returns a Windows style path (D:/a/...) that both bash and .exe programs understand.
if [[ "$OSTYPE" == "msys"* ]] || [[ "$OSTYPE" == "cygwin"* ]]; then
    WINDOWS_HOST=1
    WINDOWS_EXAMPLE_DIR="$(cd "$WINDOWS_SCRIPTS_DIR/.." && pwd -W)"
else
    WINDOWS_HOST=0
    WINDOWS_EXAMPLE_DIR="$(cd "$WINDOWS_SCRIPTS_DIR/.." && pwd)"
fi

WINDOWS_SHELL_DIR="$WINDOWS_EXAMPLE_DIR/shells/windows"
WINDOWS_SDK_DIR="$WINDOWS_EXAMPLE_DIR/webview2-sdk"

# The pinned WiX Toolset that fetch-wix.sh extracts, which package-windows.sh builds the MSI installer with.
WIX_VERSION="3.14.1"
WINDOWS_WIX_ROOT="$WINDOWS_EXAMPLE_DIR/wix"
WINDOWS_WIX_DIR="$WINDOWS_WIX_ROOT/wix-$WIX_VERSION"

# The name of the directory inside an install prefix that holds the exe, which is the whole app.
WINDOWS_APP_DIR_NAME="ziggy-example"

#
# Prints the Zig target for an architecture name, or fails. Only x64 can be built: the WebView2 loader is linked from the SDK's
# static library, which needs the -windows-msvc target, and Zig 0.16's standard library does not compile for aarch64-windows-msvc.
# Usage: windows_zig_target <x64>
#
windows_zig_target() {
    case "$1" in
        x64)
            echo "x86_64-windows-msvc"
            ;;
        arm64)
            echo "Windows arm64 cannot be built yet: it needs the aarch64-windows-msvc target, which Zig 0.16's standard library does not compile." >&2
            return 1
            ;;
        *)
            echo "Unknown architecture \"$1\". Use x64." >&2
            return 1
            ;;
    esac
}

#
# Fails, naming what is missing and how to get it, when any of the given commands is not on PATH.
# Usage: windows_require_commands <command>...
#
windows_require_commands() {
    local missing=""
    local command_name
    for command_name in "$@"; do
        if ! command -v "$command_name" > /dev/null 2>&1; then
            missing="$missing $command_name"
        fi
    done
    if [ -n "$missing" ]; then
        echo "Not found on PATH:$missing. Run \"mise install\" from the repository root, and put the tools it installs on PATH:" >&2
        echo "add %LOCALAPPDATA%\\mise\\shims to PATH, or activate mise in your shell." >&2
        exit 1
    fi
}

#
# Succeeds when Microsoft's C++ toolchain and the Windows SDK are installed, the two things Zig looks for to build the
# -windows-msvc target: a Visual Studio or Build Tools instance with the x64 C++ tools, found with vswhere, and the
# Windows 10/11 SDK root in the registry. Prints nothing.
#
windows_msvc_toolchain_installed() {
    if [ "$WINDOWS_HOST" != "1" ]; then
        return 1
    fi
    local vswhere
    vswhere="$(printenv 'ProgramFiles(x86)')/Microsoft Visual Studio/Installer/vswhere.exe"
    if [ ! -f "$vswhere" ]; then
        return 1
    fi
    local vc_tools_path
    vc_tools_path="$("$vswhere" -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)"
    if [ -z "$vc_tools_path" ]; then
        return 1
    fi

    # reg takes /v as an argument, which Git Bash would otherwise rewrite into a path.
    MSYS2_ARG_CONV_EXCL='*' reg query 'HKLM\SOFTWARE\Microsoft\Windows Kits\Installed Roots' /v KitsRoot10 > /dev/null 2>&1
}

#
# Fails, saying how to get them, when Microsoft's C++ toolchain or the Windows SDK is not installed on this Windows machine.
# On any other host there is no vswhere or registry to look in, so Zig is left to find what it needs or report it.
# Usage: windows_require_msvc_toolchain
#
windows_require_msvc_toolchain() {
    if [ "$WINDOWS_HOST" != "1" ]; then
        return 0
    fi
    if ! windows_msvc_toolchain_installed; then
        echo "Building the Windows app needs Microsoft's C++ toolchain and the Windows SDK, and they were not found on this machine." >&2
        echo "Run \"bun run --filter=ziggy-example setup\" from the repository root under Git Bash to install them, or add the" >&2
        echo "\"Desktop development with C++\" workload in the Visual Studio Installer. See setup-windows.md." >&2
        exit 1
    fi
}

#
# Downloads a file unless it is already there with the right hash, then fails if the hash is wrong.
# Usage: fetch_verified <url> <file> <sha256>
#
fetch_verified() {
    local url="$1"
    local file="$2"
    local expected="$3"
    if [ ! -f "$file" ]; then
        echo "Downloading $url"
        curl --fail --silent --show-error --location --output "$file" "$url"
    fi
    local actual
    actual="$(sha256sum "$file" | cut -d ' ' -f 1)"
    if [ "$actual" != "$expected" ]; then
        echo "The sha256 of $file is $actual, expected $expected. Delete the file and run again, or check the pin." >&2
        return 1
    fi
}

#
# Fails, saying how to get it, when the pinned WiX Toolset has not been fetched into WINDOWS_WIX_DIR.
# Usage: windows_require_wix
#
windows_require_wix() {
    if [ ! -f "$WINDOWS_WIX_DIR/candle.exe" ] || [ ! -f "$WINDOWS_WIX_DIR/light.exe" ]; then
        echo "Packaging the Windows app needs WiX Toolset $WIX_VERSION in $WINDOWS_WIX_DIR, and it is not there." >&2
        echo "Run \"bun run --filter=ziggy-example setup\" from the repository root under Git Bash to fetch it. See setup-windows.md." >&2
        exit 1
    fi
}

#
# Prints the app's version, read from package.json.
#
windows_app_version() {
    jq -r '.version' "$WINDOWS_EXAMPLE_DIR/package.json"
}

#
# Extracts a zip file into a directory. Git Bash has no unzip, so on Windows the tar that ships with Windows is used.
# Usage: windows_unzip <zip file> <directory>
#
windows_unzip() {
    if command -v unzip > /dev/null 2>&1; then
        unzip -oq "$1" -d "$2"
    elif [ "$WINDOWS_HOST" = "1" ]; then
        "$SYSTEMROOT/System32/tar.exe" -xf "$1" -C "$2"
    else
        echo "Neither unzip nor the Windows tar is available to extract $1." >&2
        return 1
    fi
}

#
# Creates a zip file of a directory's contents, keeping the directory's own name as the top level folder.
# Usage: windows_zip <zip file> <parent directory> <directory name inside it>
#
windows_zip() {
    local zip_file="$1"
    local parent="$2"
    local name="$3"
    rm -f "$zip_file"
    if command -v zip > /dev/null 2>&1; then
        (cd "$parent" && zip -qr "$zip_file" "$name")
    elif [ "$WINDOWS_HOST" = "1" ]; then
        (cd "$parent" && "$SYSTEMROOT/System32/tar.exe" -a -cf "$zip_file" "$name")
    else
        echo "Neither zip nor the Windows tar is available to create $zip_file." >&2
        return 1
    fi
}
