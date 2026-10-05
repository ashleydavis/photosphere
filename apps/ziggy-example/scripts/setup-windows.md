# setup-windows.sh

One time setup for building the Windows shell. It runs `fetch-webview2.sh`, so see [fetch-webview2.md](fetch-webview2.md) for what it downloads.

It is run on Windows by `bun run --filter=ziggy-example setup` from the repository root, through [setup.sh](setup.md). It takes no arguments. It needs `curl`, `sha256sum` and `unzip` (or the Windows `tar`), and expects `bun install` and `mise install` to have been done.
