# package-macos

Builds the MacOS app in Release and packs `ziggy-example-<version>-macos-<arch>.dmg` (with a link to `/Applications`) and `ziggy-example-<version>-macos-<arch>.zip`. The version comes from `apps/ziggy-example/package.json`. The app is ad hoc signed, not notarized.

Run it on a Mac: `mise exec -- bash apps/ziggy-example/scripts/package-macos.sh`.

## Arguments

- `--arch <arm64|x86_64>`: default: this Mac's.
- `--output-dir <dir>`: where the artifacts and the build files go. Default: `shells/macos/zig-out/package`.
