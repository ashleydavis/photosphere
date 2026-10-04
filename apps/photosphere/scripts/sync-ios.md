# sync-ios.sh

Brings the iOS project up to date with the core and the UI. Invoked as `bun run --filter=ziggy sync:ios`.

Builds the UI (`bundle-ui.sh`) and the core as a static library for the iOS targets (`bundle-core.sh`), and copies both into the Xcode project so it is current when opened in Xcode or built by `xcodebuild`. Takes no arguments. Runs on MacOS only.
