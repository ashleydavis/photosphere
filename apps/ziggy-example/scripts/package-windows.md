# package-windows.sh

Builds a ReleaseSafe app and packages it twice, unsigned: a zip and an NSIS installer. Both go in `apps/ziggy-example/shells/windows/package/` (gitignored) and are named `ziggy-example-<version>-windows-<arch>.zip` and `.exe`, with the version read from `apps/ziggy-example/package.json`.

Run it as `bash apps/ziggy-example/scripts/package-windows.sh [arch]`.

- `arch`: `x64` or `arm64`. Default `x64`.

The installer is described by `package-windows.nsi` beside the script and needs `makensis` on the PATH. The script passes it `VERSION`, `ARCH`, `SOURCE_DIR` and `OUTPUT_FILE` as defines. The installer installs for the current user only. The zip needs `zip`, or `tar.exe` on Windows.
