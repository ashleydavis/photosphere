# Driving the Apps as an Agent

How an agent taking a human through the manual tests (with `/test:manual-walkthrough`) performs the UI steps itself, on each platform. Each test ends with an **Agent notes** section that links here and adds what is particular to that test.

The rules in the [README](README.md) still apply: every step is run, in order. Driving the app yourself changes who presses the button, not which buttons are pressed. Read the result of every step from a screenshot before saying it matched the expectation.

Screenshots go in the project's `tmp/walkthrough/` folder, which is not committed.

## Android (emulator or device)

adb is at `$ANDROID_HOME/platform-tools/adb`. Find the device's serial with `adb devices` and pass it to every command with `-s <serial>`, since more than one emulator may be running.

- **Screenshot**: `adb -s <serial> exec-out screencap -p > tmp/walkthrough/<name>.png`, then read the image.
- **Tap**: `adb -s <serial> shell input tap X Y`, in the device's own pixels. A screenshot may be shown to you scaled down, so scale the coordinates you read from it back up to the device's resolution, which `adb -s <serial> shell wm size` prints.
- **Type**: `adb -s <serial> shell input text '<text>'` into the field that has focus. Tap the field first. A space is typed as `%s`.
- **Scroll or swipe**: `adb -s <serial> shell input swipe X1 Y1 X2 Y2 <milliseconds>`. A swipe with the same start and end point and a long duration (for example 800) is a press and hold.
- **Back**: `adb -s <serial> shell input keyevent KEYCODE_BACK`.

System dialogs, such as the photos and videos permission, the notifications permission and the system's request to delete a photo, are ordinary screens to adb: take a screenshot, find the button and tap it the same way. The system settings app (to grant or revoke a permission) and the system gallery app (to check a photo is there or gone) are driven the same way too.

Screenshots and taps, including on the system permission dialogs, have been run against an emulator from the emulator pool.

## iOS simulator

- **Screenshot**: `xcrun simctl io <udid> screenshot --type=png tmp/walkthrough/<name>.png`, then read the image. `xcrun simctl list devices booted` lists the booted simulators and their udids.
- **Tap**: `simctl` has no command to tap, type or swipe, so there is no built-in way for an agent to press anything on the simulator. On iOS the human does every UI step. The agent runs the commands, takes screenshots to read the result, and tells the human what to press.
- **Photo permission**: `xcrun simctl privacy <udid> grant photos <bundle id>` and `revoke photos` change the permission without the dialog, as `apps/photosphere-smoke-tests/lib/ios.sh` does (the bundle id is set there). Use this only for permission set up in a test's Prep. A step that tests the dialog itself is answered by the human.

None of the iOS part has been run, because there was no Mac to run it on.

## Desktop (Linux)

The agent drives a test-hooks build of the desktop app over its control connection, the way `apps/photosphere-smoke-tests` does. The full instructions are in the "Driving the desktop app yourself" section of `.claude/commands/test/manual-walkthrough.md`. In short:

- Build it into the project's `tmp/` with `-Dtest-hooks=true`, and start it in the background with the test's own export block plus the test-mode variables the smoke tests set.
- Send `click`, `type`, `navigate`, `menu`, `pick-answer`, `get-value`, `long-press`, `long-press-click`, `screenshot` and `quit` as `control_command`, `send_command` and `read_value` in [`apps/photosphere-smoke-tests/lib/common.sh`](../../../apps/photosphere-smoke-tests/lib/common.sh) do. Elements are found by the `data-id` given in brackets in each test step.
- Queue `pick-answer` before clicking a button that opens a file picker, folder picker or save dialog. Open an asset with `long-press-click` on `gallery-thumb` and select one with `long-press`, since there is no hover.
- Use a visible window while the human is following along, and quit every instance when its test is done.
- Leave a step that needs a human to judge, such as whether a video plays, open in a visible window for the human.
