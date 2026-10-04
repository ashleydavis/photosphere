# sync-windows.sh

Brings the Windows shell project up to date with the core and the UI. Invoked as `bun run --filter=ziggy sync:windows`.

Builds the UI (`bundle-ui.sh`) and the core as a static library for Windows (`bundle-core.sh`), and copies both into `shells/windows`. Takes no arguments. Runs on Windows, and cross-compiles from Linux.
