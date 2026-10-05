# clean-windows.sh

Removes what `sync-windows.sh` put in `apps/ziggy-example/shells/windows/zig-out` and the packages `package-windows.sh` put in `apps/ziggy-example/out/windows`. It deletes one named file at a time and then removes the directories that are left empty. It does not delete the Zig cache or the downloaded SDK.

Run it as `bash apps/ziggy-example/scripts/clean-windows.sh`. It takes no arguments.
