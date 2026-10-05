# clean-windows.sh

Removes what `sync-windows.sh` and `package-windows.sh` put under `apps/ziggy-example/shells/windows` (`zig-out`, and `package` with the installer's WiX object file), and the zip and MSI in `apps/ziggy-example/out/windows`. It deletes one named file at a time and then removes the directories that are left empty. It does not delete the Zig cache or the downloaded SDK and WiX Toolset.

Run it as `bash apps/ziggy-example/scripts/clean-windows.sh`. It takes no arguments.
