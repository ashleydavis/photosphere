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
