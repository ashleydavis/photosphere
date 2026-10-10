# clean-windows.sh

Removes what `sync-windows.sh` and `package-windows.sh` put under `apps/photosphere/shells/windows` (`zig-out`, and `package` with the installer's WiX object file), and the zip and MSI in `apps/photosphere/out/windows`. It deletes one named file at a time and then removes the directories that are left empty. It does not delete the Zig cache or the downloaded SDK and WiX Toolset.

Run it as `bun run --filter=ziggy clean:windows`. It takes no arguments.
