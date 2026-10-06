# Ziggy example, iOS shell

A UIKit app: one view controller whose view is Ziggy's `WKWebView`. All the Ziggy behaviour is in the `ZiggyShellIOS` Swift package (`packages/ziggy/native/ios`), referenced as a local package. The deployment target is iOS 14.0. The app has no network permissions to declare, because the example page is loaded from a file. There is no way to quit an iOS app, so the test control connection's quit command destroys the core and ends the process.

## Web view API used

`WKWebView`, `WKUserScript` (document start, main frame), `WKScriptMessageHandler` named `ziggy`, `evaluateJavaScript`, `loadFileURL(_:allowingReadAccessTo:)`, `WKNavigationDelegate`, `WKUIDelegate`, and `UIApplication.open` for external links.

## Building

The project links `libziggy_example.a` from the directory in the `ZIGGY_NATIVE_DIR` build setting (default `zig-out` beside the project) (which has the page embedded in it, so the app has no page files of its own). That library is built for one SDK and architecture, so fill the directory with `scripts/sync-ios.sh --sdk simulator|device` for the one you build. The build and run scripts do it for you. Code signing is off, so the app runs on a simulator and a device build must be signed before it installs.

## What you do on the Mac

- Install Xcode 14.2, `jq`, and run `mise install` and `bun install` in the repository. `scripts/setup-ios.sh` checks the tools.
- Make sure an iOS simulator exists (`xcrun simctl list devices available`). Set `ZIGGY_IOS_SIMULATOR` to pick one.
- Run `mise exec -- bash apps/ziggy-example/scripts/run-ios.sh`.
- Nothing here was compiled when it was written (it was authored on Linux), so the first build may need fixes.

## File and folder pickers

The pick-files and pick-folder requests open a `UIDocumentPickerViewController`. Files are opened as copies in the app's temporary directory. A picked folder is accessed through a security scoped resource that the shell starts and never stops, so it is usable until the process ends and denied again after a restart until the user picks it again. The pick-file (save) request always fails with an error, because iOS has no dialog for choosing where to save. Not compiled or run. See the package README.
