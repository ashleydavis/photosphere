# package-windows.sh

Builds a ReleaseSafe app and packages it twice, unsigned: a zip and an MSI installer. Both go in `apps/photosphere/out/windows/` (gitignored) and are named `photosphere-<version>-windows-<arch>.zip` and `.msi`, with the version read from `apps/photosphere/package.json`. The build they are made from is installed in `apps/photosphere/shells/windows/package/<arch>/`, along with the installer's WiX object file.

Run it as `bun run --filter=ziggy package:windows -- [arch]`.

- `arch`: `x64`. The default. `arm64` is refused, because the WebView2 loader is linked statically and that needs the `aarch64-windows-msvc` target, which Zig 0.16's standard library does not compile.

The installer is described by `package-windows.wxs` beside the script and built with the WiX Toolset that `fetch-wix.sh` puts in `apps/photosphere/wix/`: `candle` compiles it with the `Version` and `SourceDir` variables, and `light` links the MSI. The script stops with a message before building anything when WiX has not been fetched; run setup. The MSI installs for the current user only, into `%LOCALAPPDATA%\Programs\Photosphere`, with a Start menu shortcut, and needs no administrator rights. Its version must be numeric (`major.minor.build`), which Windows Installer requires. The zip needs `zip`, or `tar.exe` on Windows.
