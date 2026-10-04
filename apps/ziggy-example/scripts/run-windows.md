# run-windows.sh

Builds the Windows app with `sync-windows.sh` (x64, Debug, into `shells/windows/zig-out`) and then runs `ziggy-example.exe`.

Run it as `bash apps/ziggy-example/scripts/run-windows.sh [app arguments]`. Every argument is passed to the app, for example `-geometry=1000x700+50+50` for a window of that size at that position.
