# Ziggy shell for Android

Ziggy's Android framework code: a Java library module (no Kotlin) that an app's Gradle project includes. The app's root `build.gradle` defines the shared versions in `ext` (`compileSdkVersion`, `minSdkVersion`, `androidxWebkitVersion`).

`ZiggyShell` takes an activity and a `WebView` and:

- Configures the web view: JavaScript and DOM storage on (so `localStorage` and IndexedDB work; `localStorage` reaches the disk a few seconds after the page sets it); file access, file-URL access, content access and universal access off (the bundled page is answered from the core library through `shouldInterceptRequest`, so it needs no file access); no cleartext or mixed content.
- Injects `ziggy-inject.js` (embedded in the core library, so the app supplies nothing) with `WebViewCompat.addDocumentStartJavaScript` (androidx.webkit), so it runs before the page's own scripts. There is no fallback: a web view without that feature makes `start` throw, because running the script when the page starts loading races the page's first script and would lose quietly.
- Exposes `window.ZiggyAndroid.postMessage(string)` with `addJavascriptInterface`, which the injected script posts through.
- Delivers core messages with `evaluateJavascript("window.__ziggyReceive(<json>);")` on the main thread, in the order they arrived. The core delivers from any thread, so each message is copied and posted to the main looper.
- Decides every navigation with the core's origin check: `shouldOverrideUrlLoading` opens http, https and mailto links in the system browser and blocks the rest. A request for something on the page (an image, a video, a script request) is not checked, as on every other platform, so the page can load media from a server on the loopback address. `shouldInterceptRequest` answers the app's own page from the core library.
- In a test hooks core library, when the launching Intent has the boolean extra `ziggy.testMode`, reads the string extra `ziggy.testPortFile`, and appends `?testMode=1` to the page URL.

The activity calls `start` in `onCreate` and `destroy` in `onDestroy`. `destroy` calls the core's destroy once and nothing is delivered after it.

The native methods (`ZiggyNative`) are implemented in Zig, in `packages/ziggy/core/src/lib/jni.zig`, which the app's core library exports with `ziggy.jni.exportJni(...)` for an Android target. The Java side is the web view and the lifecycle, and everything that crosses to the core goes through that file. Messages cross as UTF-8 byte arrays.

The module is built by the app's Gradle project, not on its own.

## File and folder pickers

The core asks the shell for a picker through the `pick_paths` host callback, from a worker thread. The Zig side (`jni.zig`) calls `ZiggyHost.pickPathsJson(kind, title, initialName)` on that thread, and `ZiggyShell` starts a Storage Access Framework activity with `startActivityForResult` on the main thread and blocks the worker until the activity's `onActivityResult` answers. The activity must forward `onActivityResult` to `ZiggyShell.onActivityResult`. The answer is a JSON array of strings, as UTF-8 bytes, and `[]` when the user cancelled.

- Open files: `ACTION_OPEN_DOCUMENT`, openable, any type, multiple allowed. Each chosen document is copied into its own directory under the app's cache directory (`ziggy-picked/<unique>/<display name>`) and the answer is those file system paths, so the page and the core get real paths. The copies are not deleted by Ziggy; the cache directory is the system's to clear.
- Folder: `ACTION_OPEN_DOCUMENT_TREE`. The answer is the tree Uri string (`content://...`). A tree Uri is not a file system path: Android does not give an app a path to a folder the user picked, only a Uri to read and write through a `ContentResolver`.
- Save: `ACTION_CREATE_DOCUMENT` with the suggested name as `EXTRA_TITLE`. The answer is the document's Uri string, which is also not a file system path.
- The title is ignored: the system pickers have no title to set (`EXTRA_TITLE` is the file name for a save).
- Strings pass to Java with `NewStringUTF`, which uses modified UTF-8, so a title or suggested name with a character outside the basic multilingual plane is not carried correctly. The answer, which can hold any path, crosses as bytes and is exact.
- Cancelling (including the back button) is a normal `[]`. A failure to show or read a picker is logged and answered as a failure, which the core reports to the page. Quitting, or destroying the shell, with a picker open closes the picker and answers `[]`, so the core's workers can stop.

The keep-alive callback starts and stops a foreground service. How it works is in the architecture document. The library's manifest declares the service and its permissions. An app that serves media from a loopback server also needs the `INTERNET` permission and a network security config that allows cleartext to `127.0.0.1`, as the example does.
