# package-ios

Runs `xcodebuild archive` for a device with code signing off (`CODE_SIGNING_ALLOWED=NO`), producing `ziggy-example-<version>-ios-arm64.xcarchive`, and packs the unsigned app from it as `ziggy-example-<version>-ios-arm64.ipa`. The version comes from `apps/ziggy-example/package.json`. The artifacts must be signed before they install on a device.

Run it on a Mac: `mise exec -- bash apps/ziggy-example/scripts/package-ios.sh`.

## Arguments

- `--output-dir <dir>`: where the artifacts and the build files go. Default: `shells/ios/zig-out/package`.
