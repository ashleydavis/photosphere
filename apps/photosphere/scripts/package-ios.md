# package-ios

Runs `xcodebuild archive` for a device with code signing off (`CODE_SIGNING_ALLOWED=NO`), producing `photosphere-<version>-ios-arm64.xcarchive`, and packs the unsigned app from it as `photosphere-<version>-ios-arm64.ipa`, both in `out/ios`. The build files go in `shells/ios/zig-out/package`. The artifacts must be signed before they install on a device.

Run it on a Mac: `bun run --filter=ziggy package:ios`.

## Arguments

- `--output-dir <dir>`: where the packages go. Default: `out/ios`.
- `--version <version>`: the version in the file names and the app's marketing version, such as `1.2.3` for the tag `ios-v1.2.3` or `dev-nightly.20260101` for a nightly. Default: the version in `apps/photosphere/package.json`.
