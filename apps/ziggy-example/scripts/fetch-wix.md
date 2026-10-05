# fetch-wix.sh

Downloads the pinned WiX Toolset binaries zip from GitHub into `apps/ziggy-example/wix/` (gitignored), verifies it against a pinned sha256, and extracts it to `wix/wix-<version>/`. `package-windows.sh` builds the MSI installer with the `candle.exe` and `light.exe` in there. Nothing is installed: no installer runs and no administrator approval is needed. The tools run on the .NET Framework 4 that Windows ships with.

Run it as `bash apps/ziggy-example/scripts/fetch-wix.sh`. It takes no arguments and can be run again safely: a download already present with the right hash is reused. `setup-windows.sh` runs it.

The version is `WIX_VERSION` in `windows-common.sh`, which is where the tools are looked for. The release URL and the sha256 are in this script. The hash was computed with `sha256sum` on the zip as GitHub served it at the time of pinning. To update the pin, change all three together.

Why WiX 3: it is licensed under the Microsoft Reciprocal License alone, and its binaries come as a zip that runs without installing. WiX 6 and later put their binary releases under an Open Source Maintenance Fee agreement, which charges revenue-generating users above a revenue threshold, and are delivered as an MSI that needs administrator rights to install or as .NET tool packages that need the .NET SDK.
