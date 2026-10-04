#!/usr/bin/env bash

# One time setup for building the Windows shell: fetches the WebView2 SDK. See setup-windows.md.

set -euo pipefail

bash "$(dirname "${BASH_SOURCE[0]}")/fetch-webview2.sh"
