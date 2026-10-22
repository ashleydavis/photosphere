# iOS native app

The iOS native app is a Swift app that hosts a `WKWebView` and passes messages between the page and the Zig core library.

## What it does

- Injects the `window.ziggy` script with a `WKUserScript`, receives page messages in a `WKScriptMessageHandler`, calls `ziggy_create` and `ziggy_post_message` through Ziggy's `ZiggyNativeIOS` package (taken from Ziggy's repository, see [Photosphere on Ziggy](../../../../docs/photosphere-on-ziggy.md)), and delivers Zig messages to the page on the main thread.
- Provides what iOS forces, each as a host request the core makes by name and answers in `PhotosphereHostRequests.swift` or the file it hands the method to: the photo permission and the Photos framework (`MediaLibraryHostRequests.swift`), export and share with `UIActivityViewController` (`ExportHostRequests.swift`), the Keychain (`SecureStore.swift`), the connection type (`NetworkHost.swift`), the hold that keeps the app running during a background pass (`BackgroundWakeHold.swift`). The core makes the decisions.
- Runs the three background processing tasks (auto-import, background-sync, background-prefetch) in `BackgroundPasses.swift`. Each is registered at launch and scheduled when the app leaves the screen while the core's background loops are running. When the system runs one, the native app asks the core to start its background work, and when the system's time is up it cancels the loop that task stands for.
- Allows cleartext loopback to the asset server through the App Transport Security setting in `Info.plist`.

## Media tools

ImageMagick and FFmpeg are built into the core static library and run in the app's process, so the project links nothing for them. The libraries are built by the core's Zig build from `vendor/` (see `docs/mobile-native-media.md`).

## Project and build

An Xcode project that builds with Xcode 14.2 on macOS 12.7.6. No version is raised. `sync:ios` builds the frontend and the core as a static library (`libphotosphere.a`, with the frontend embedded) into `native/ios/zig-out`; the bundle id is `au.com.codecapers.photosphere.ziggy`, then `xcodebuild` builds the app. `open:ios` opens the project in Xcode. Runs on MacOS only. See [Photosphere App](../../README.md).

## Icon

The app icon is the `AppIcon` set in `Photosphere/Assets.xcassets`, made from `icons/photosphere-1024.png`.
