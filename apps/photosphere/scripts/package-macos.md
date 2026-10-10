# package-macos

Builds the MacOS app in Release and packs `out/macos/photosphere-<version>-macos-<arch>.dmg` (with a link to `/Applications`) and `out/macos/photosphere-<version>-macos-<arch>.zip`. The build files go in `shells/macos/zig-out/package`. The version comes from `apps/photosphere/package.json`. The app is ad hoc signed, not notarized.

Run it on a Mac: `bun run --filter=ziggy package:macos`.

## Arguments

- `--arch <arm64|x86_64>`: default: this Mac's.
- `--output-dir <dir>`: where the packages go. Default: `out/macos`.
