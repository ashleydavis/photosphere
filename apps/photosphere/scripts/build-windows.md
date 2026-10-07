# build-windows.sh

Runs `sync-windows.sh`, then builds the Windows shell with `zig build` from the root of the repository. Invoked as `bun run --filter=ziggy build:windows`.

Takes no arguments. Runs on Windows, and cross-compiles from Linux.
