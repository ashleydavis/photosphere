# package-macos.sh

Builds the MacOS app (`build-macos.sh`) and packages it for distribution. Invoked as `bun run --filter=ziggy package:macos`.

Produces a `dmg` with `hdiutil` and a `zip`, unsigned and not notarised, in the MacOS output folder, named `photosphere-<version>-mac-<arch>.<ext>`. Takes no arguments. Runs on MacOS only.
