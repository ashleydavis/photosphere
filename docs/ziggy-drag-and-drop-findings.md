# Ziggy drag and drop

How a file dropped on the window gets its real path to the page on each platform, with the evidence for each. Each item is marked proven (run and seen), documented (read in a source, not run here) or not run (code written, not run here).

## What the page needs

Photosphere's import page handles a drop in an async function. For each File in `dataTransfer.files` it calls `platform.getPathForFile(file)`, which on Electron is `webUtils.getPathForFile`. The call returns the path at once. Dropped folders matter, because the import takes directories. The page only uses the path and never reads a dropped file's contents.

## How it works, on every desktop platform

1. The shell reads the paths of a drop natively and records them with the core (`ziggy_files_dropped`). The core keeps the paths of the last drop.
2. The inject script catches a drop of files before the page does, asks the core for the paths of the last drop (`get-dropped-paths`), and fires the drop again holding one File per path. The script makes each File with the item's name, and remembers its path.
3. `window.ziggy.getPathForFile(file)` is synchronous and returns the remembered path, as Electron's does. The page runs unchanged. A folder is a File named for the folder. The Files are empty, which the page does not mind because it only uses the path.

The same inject script runs on every platform. Only how the shell reads the paths differs.

Proven on Linux, by real drops of a file with a space in its name, a plain file, a file with non-ASCII characters in its name, a folder, and three files at once: the shell recorded the paths before the page asked for them, the page received a File per item, and `getPathForFile` returned the right path for each. The page received one File per item dropped, and a drop of three files gave three.

Documented: the `DragEvent` constructor accepts a `dataTransfer` option and has been available in all major browsers since September 2020 ([MDN, DragEvent()](https://developer.mozilla.org/en-US/docs/Web/API/DragEvent/DragEvent)).

## Linux (WebKitGTK): proven

- Proven: for a real drop from the file manager the page sees the types `text/uri-list` and `text/html`, no files, and an empty string from `getData("text/uri-list")`. The shell's `drag-data-received` handler gets the full path of each dropped file and folder.
- Documented: [koushi-matrix pull request 974](https://github.com/shinaoka/koushi-matrix/pull/974) and [vireo issue 126](https://github.com/hyprlab/vireo/issues/126) report the same behaviour. [WebKit pull request 73114](https://github.com/WebKit/WebKit/pull/73114), still open, says a security fix for CVE-2025-13947 made `DataTransfer::allowsFileAccess()` return false on every non-Cocoa port.
- Documented: [wry on Linux](https://raw.githubusercontent.com/tauri-apps/wry/dev/src/webkitgtk/drag_drop.rs) reads the paths the same way, from `drag-data-received` with `data.uris()`.
- Documented: [GTK's documentation of drag-data-received](https://docs.gtk.org/gtk3/signal.Widget.drag-data-received.html) says the default handler runs after handlers added with `g_signal_connect`. WebKit's handling is the default handler, so the shell's handler runs first.

## Windows (WebView2): documented, not run

- The inject script posts the dropped Files with `chrome.webview.postMessageWithAdditionalObjects("ziggy-file", files)`. The shell's message handler reads each File's path with `get_AdditionalObjects` and `ICoreWebView2File::get_Path` and records the paths with the core. Then the shared steps above run.
- Documented: [ICoreWebView2File](https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2file) says "You can use this object to obtain the path of a File dropped on WebView2" and gives a sample that does this. [ICoreWebView2WebMessageReceivedEventArgs2](https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2webmessagereceivedeventargs2) says a WebMessage object can be an `ICoreWebView2File`, from WebView2 1.0.1774.30. The SDK this repo pins is 1.0.3856.49.
- Documented: [wry on Windows](https://raw.githubusercontent.com/tauri-apps/wry/dev/src/webview2/drag_drop.rs) uses a different route, an `IDropTarget` registered with `RegisterDragDrop` that reads the paths with `DragQueryFileW`.
- Not run: the shell code compiles for Windows from Linux and has not been run.

## macOS (WKWebView): documented, not run

- The shell subclasses the web view, overrides `performDragOperation`, reads the file paths from the dragging pasteboard, records them with the core, and then lets the web view carry on. Then the shared steps above run.
- Documented: [wry on macOS](https://raw.githubusercontent.com/tauri-apps/wry/dev/src/wkwebview/drag_drop.rs) overrides the same methods on a web view subclass and reads the paths from the dragging pasteboard.
- Not run: the Swift has not been compiled or run.

## Android and iOS

A phone has no file drop. The inject script's drop handling never fires there.

## How it is tested

- Linux, by hand: drop files and a folder on the example's drop box and read each path in the box.
- Everywhere: the example's smoke scenario drops a file with the `drop` and `drop-file` test commands, which run the core and page parts of the design. They do not run the shell's reading of a real drop.
- macOS and Windows, by hand on those machines.
