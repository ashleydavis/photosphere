# sync-linux.sh

Brings the Linux shell project up to date with the core and the UI. Invoked as `bun run --filter=ziggy sync:linux`.

Builds the UI (`bundle-ui.sh`) and the core as a static library for Linux (`bundle-core.sh`), and copies both into `shells/linux`. Takes no arguments. Runs on Linux and MacOS.
