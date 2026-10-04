# setup-windows.sh

One time setup for building the Windows shell. It runs `fetch-webview2.sh`, so see [fetch-webview2.md](fetch-webview2.md) for what it downloads.

Run it as `bash apps/ziggy-example/scripts/setup-windows.sh`. It takes no arguments. It needs `curl`, `sha256sum` and `unzip` (or the Windows `tar`), and expects `bun install` and `mise install` to have been done.
