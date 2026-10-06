# run.sh

Runs the Ziggy example's smoke test scenarios for one platform. Invoked by the root `package.json` scripts `test:ziggy-example`, `test:ziggy-example:and` and `test:ziggy-example:ios`, never directly.

## Arguments

- `<platform>`: `linux`, `windows`, `macos`, `android` or `ios` (a connected iPhone or iPad when there is one, see `lib/ios-device.sh`, otherwise a simulator). Each has a platform library in `lib/<platform>.sh` that builds the app, starts it and stops it.
- `[scenario]`: optional scenario number or name, to run one scenario.

## Behaviour

Builds the example twice for the platform, once with the test hooks and once without. Then runs each scenario's `test.sh`, one after another, giving each its own temporary directory and a held-to timeout. A scenario drives the running app through the test control connection (see `lib/common.sh` for what a scenario can do and what a platform library implements). Every process started is recorded as it is launched, and any still running at the end fails the run and is stopped.

## Scenarios

- `1-reply`: the page loads and the Zig core answers a request.
- `2-short-task`: a short task sends output and progress and its job goes away.
- `3-long-task-with-children`: a long task queues children and waits for them while the page stays responsive.
- `4-cancel-long-task`: cancelling a source stops its task early.
- `5-cancel-one-of-several-sources`: cancelling one source leaves the other tasks running.
- `6-edges`: a large payload, text with quotes and non-ASCII characters, an error reply, a failing task, a file in the data directory and the native host callback.
- `7-control-reports-bad-commands`: the control connection answers a line that is not a command with an error and keeps working.
- `8-release-has-no-hooks`: the release build has no control connection.
- `9-quit-ends-everything`: quitting with tasks running ends the app and everything it started.
- `10-pickers`: the file and folder buttons show what the dialogs return, several files, a folder, a save location and a cancel. The scenario answers each dialog through the control connection, so no native dialog is shown.
- `16-media-server`: the page loads an image and a video from the loopback HTTP server in the example's core, and asks it for a range of bytes. The video is read to its metadata only, because the Android emulator's software video decoding crashes the emulator.
- `17-page-storage`: a value the page writes to `localStorage` and to IndexedDB is still there after the app is quit and started again. It waits before the restart because Android's web view writes `localStorage` to disk a few seconds after the page sets it.
- `18-keep-alive-survives-leaving`: a keep-alive background task goes on counting in a file in the data directory when the window is closed (a desktop) or the app is sent to the background (a phone). On a desktop the app then ends by itself with the task, and on Android the foreground service is running.

The scenarios in `desktop-only` run on Linux, Windows and macOS and not on a phone, because the menu is a desktop feature. They choose menu items through the control connection's `menu` command, which calls the shell's own function for the item, the one a click runs, so the shell's actions really happen:

- `11-menu-page-actions`: About, and the items that start and cancel tasks, do what their buttons do.
- `12-menu-view`: Reload starts the page afresh, and the zoom items change the size of the area the page is drawn in.
- `13-menu-edit`: Select All, Cut, Paste, Copy, Undo and Redo edit the page's text area.
- `14-menu-quit`: Quit ends the app and everything it started, with tasks running.
- `15-menu-devtools`: Toggle Developer Tools opens and closes the developer tools, seen the way each platform shows them.
- `19-normal-task-ends-with-window`: closing the window with only a normal background task running ends the app.
- `20-drop-files`: a file dropped on the window gets its real path from `getPathForFile`, and a file of another size does not. The drop is faked in two steps, because no tool can drag a file into the window: the `drop` command records it with the core and `drop-file` gives the page a drop event. The shell's own reading of a real drop is tested by hand.

Toggle Full Screen is not smoke tested. The Linux suite runs on a virtual display with no window manager, and nothing honours a request for full screen there, so there is nothing to see change.
