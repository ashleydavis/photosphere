# package-ios.sh

Runs `sync-ios.sh`, then builds an archive with `xcodebuild archive` for Xcode 14.2 on macOS 12.7.6, without signing. Invoked as `bun run --filter=ziggy package:ios`.

Leaves the archive in the iOS output folder, named `photosphere-<version>-ios.xcarchive`. Takes no arguments. Runs on MacOS only.
