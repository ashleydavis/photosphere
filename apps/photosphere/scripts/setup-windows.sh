#!/usr/bin/env bash

# One time setup for building and packaging the Windows shell: fetches the WebView2 SDK and the WiX Toolset, and installs
# Microsoft's C++ toolchain and the Windows SDK when they are missing. See setup-windows.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/windows-common.sh"

bash "$WINDOWS_SCRIPTS_DIR/fetch-webview2.sh"

bash "$WINDOWS_SCRIPTS_DIR/fetch-wix.sh"

if ! windows_msvc_toolchain_installed; then
    if ! command -v winget > /dev/null 2>&1; then
        echo "winget is not on PATH, and setup needs it to install Microsoft's C++ toolchain and the Windows SDK. Install" >&2
        echo "\"App Installer\" from the Microsoft Store, or install Visual Studio 2022 Build Tools with the \"Desktop development" >&2
        echo "with C++\" workload by hand." >&2
        exit 1
    fi
    echo "Installing Visual Studio 2022 Build Tools with the C++ workload and the Windows SDK. Windows asks for administrator approval."
    winget_status=0
    winget install --id Microsoft.VisualStudio.2022.BuildTools --exact --accept-package-agreements --accept-source-agreements \
        --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended" || winget_status=$?
    if ! windows_msvc_toolchain_installed; then
        echo "winget exited with $winget_status and the C++ toolchain or the Windows SDK is still not found." >&2
        echo "If Visual Studio or its Build Tools were already installed, winget leaves them as they are: open the Visual Studio" >&2
        echo "Installer, choose Modify, and add the \"Desktop development with C++\" workload." >&2
        exit 1
    fi
fi
echo "Microsoft's C++ toolchain and the Windows SDK are installed."
