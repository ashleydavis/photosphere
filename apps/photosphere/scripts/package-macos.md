# package-macos

Builds the MacOS app in Release and packs `out/macos/photosphere-<version>-macos-<arch>.dmg` (with a link to `/Applications`) and `out/macos/photosphere-<version>-macos-<arch>.zip`. The build files go in `native/macos/zig-out/package`. The version comes from `--version`, or from `apps/photosphere/package.json` when it is not given. The app is ad hoc signed, not notarized.

Run it on a Mac: `bun run --filter=ziggy package:macos`.

## Arguments

- `--arch <arm64|x86_64>`: default: this Mac's.
- `--binary <Photosphere.app>`: an app already built for release (`build:macos -- --configuration Release --minify`, what the release workflow's `app-build` job makes) to package as it is. Without it the script makes that build itself.
- `--output-dir <dir>`: where the packages go. Default: `out/macos`.
- `--version <version>`: the version in the file names, such as `1.2.3` for the tag `macos-arm64-v1.2.3` or `dev-nightly.20260101` for a nightly. Default: the version in `apps/photosphere/package.json`.
