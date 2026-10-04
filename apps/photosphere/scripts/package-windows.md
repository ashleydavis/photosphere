# package-windows.sh

Builds the Windows shell (`build-windows.sh`) and packages it for distribution. Invoked as `bun run --filter=ziggy package:windows`.

Produces an installer with NSIS (`makensis`) and a `zip`, unsigned, in the Windows output folder, named `photosphere-<version>-win-<arch>.<ext>`. Takes no arguments. Runs on Windows, and on Linux where `makensis` is installed.
