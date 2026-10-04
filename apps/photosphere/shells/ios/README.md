# iOS shell

The iOS shell is a Swift app that hosts a `WKWebView` and passes messages between the page and the Zig core library.

## What it does

- Injects the `window.ziggy` script with a `WKUserScript`, receives page messages in a `WKScriptMessageHandler`, calls `ziggy_create` and `ziggy_post_message` through a bridging header that includes `ziggy.h`, and delivers Zig messages to the page on the main thread.
- Provides what iOS forces: PhotoKit and its permission flow, `PHPicker` and the document picker, export and share with `UIActivityViewController`, the Keychain, the `BGTaskScheduler` tasks (auto-import, background-sync, background-prefetch), and network type changes. Each is a host callback registered in `ziggy_create`, and the core makes the decisions.
- Allows cleartext loopback to the asset server through the App Transport Security setting in `Info.plist`.

## Project and build

An Xcode project that builds with Xcode 14.2 on macOS 12.7.6. No version is raised. `sync:ios` builds the core as a static library and copies it and the UI into the project, then `xcodebuild` builds the app. `open:ios` opens the project in Xcode. Runs on MacOS only. See [Photosphere App](../../README.md).
