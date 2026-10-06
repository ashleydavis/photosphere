# ZiggyShellIOS

Ziggy's shell code for iOS, as a Swift package (swift-tools-version 5.7, iOS 14). One class, `ZiggyBridge`, serves the app.

- `CZiggy` is a system library target whose `ziggy.h` is a link to the core's own header (`packages/ziggy/core/src/lib/ziggy.h`).
- `ZiggyShellIOS` owns the `WKWebView`, injects `ziggy-inject.js` at document start, forwards page messages to `ziggy_post_message`, delivers core messages on the main thread in order (`window.__ziggyReceive(<json>)`), decides every navigation with `ziggy_check_url`, and creates and destroys the core.

The static library with the core (`libziggy_example.a` for the example) is linked by the app project.

## Using it

```swift
let bridge = ZiggyBridge(frame: frame)  // web view, injected script, message handler
// put bridge.webView on screen
bridge.start()                          // creates the core and loads the page, which the core serves
// when the app ends:
bridge.shutdown()                       // ziggy_destroy, once
```

The page and the script that exposes `window.ziggy` (`ziggy-inject.js`, from `packages/ziggy/bridge/inject`) are both embedded in the app's core library, so the app bundle holds neither.

## Test hooks

When the linked library has the test hooks and `ZIGGY_TEST_MODE` is set, the shell starts the control connection and writes its port to the file named by `ZIGGY_TEST_PORT_FILE`.

## Failures

A failure that leaves the app unusable prints to standard error and exits non-zero. A page that fails to load, a blocked navigation and a failed delivery print to standard error and the app carries on.

## Keeping the app running

The core's `keep_alive` callback reaches `ZiggyBridge`, which takes a background task assertion (`beginBackgroundTask`) while tasks the app must be kept running for are queued or running, and gives it back when they end. The system ends the assertion after a limited time, and the app is suspended then.

## File pickers

`ZiggyPicker.swift` backs the core's `pick_paths` callback. The core calls it from a worker thread. The dialog is shown on the main thread and the worker waits on a `DispatchSemaphore`, so the main thread never blocks on it. The answer is a JSON array of paths, `[]` when the user cancelled. A failure (no window, a buffer too small, an unknown kind) prints to standard error and returns a negative number.

`UIDocumentPickerViewController` is presented over the web view's window, with the delegate's callbacks (including cancel) answering.

- Open files uses `forOpeningContentTypes: [.item], asCopy: true` with multiple selection. The paths are copies in the app's temporary directory, which the app can read and write freely until the system clears that directory. The originals are untouched.
- Folder uses `forOpeningContentTypes: [.folder]`. The shell calls `startAccessingSecurityScopedResource` on the folder and keeps access for the rest of the process, so the folder's path and everything inside it can be listed, read and written. A path from an earlier run, or a path inside the folder used after the app restarts, is denied until the user picks the folder again, because keeping access across runs needs a bookmark.
- Save: iOS has no dialog for choosing where to save a file, so the callback fails and the core replies to the request with an error.

A loopback server the page loads media from needs `NSAllowsLocalNetworking` in the app's `Info.plist`.
