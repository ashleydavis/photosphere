# run-windows.sh

Builds the Windows app with `sync-windows.sh` (x64, ReleaseSafe, into `native/windows/zig-out`) and then runs `photosphere.exe`.

Run it as `bun run --filter=ziggy run:windows -- [app arguments]`. Every argument is passed to the app, for example `-geometry=1000x700+50+50` for a window of that size at that position.
