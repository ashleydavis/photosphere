# sync-macos.sh

Brings the MacOS Xcode project up to date. Invoked as `bun run --filter=ziggy sync:macos`.

Builds the UI (`bundle-ui.sh`) and the core as a static library for MacOS (`bundle-core.sh`), and copies both into the Xcode project. Takes no arguments. Runs on MacOS only.
