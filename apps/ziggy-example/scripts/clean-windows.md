# clean-windows.sh

Removes what `sync-windows.sh` and `package-windows.sh` put under `apps/ziggy-example/shells/windows` (`zig-out` and `package`). It deletes the files an install creates one named file at a time, using the files of the built page to know which, and then removes the directories that are left empty. It does not delete the Zig cache or the downloaded SDK.

Run it as `bash apps/ziggy-example/scripts/clean-windows.sh`. It takes no arguments.
