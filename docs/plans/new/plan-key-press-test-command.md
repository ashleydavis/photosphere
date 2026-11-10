# Key press test command

## Decisions not approved by a human

- The command is `{"command": "press-key", "key": "<shortcut>"}`, with the key written in Ziggy's shortcut syntax.
- The core checks the key with `shortcut.parse` and refuses one that does not parse with `InvalidKey`.
- The core handles the command and sends the native app a new `key-press` call, with a new `has_key_press` flag in `ziggy_config`.
- The reply waits until the native app has delivered the key down and the key up.
- Phones and dev mode reply `NativeCallMissing`, as `menu` and `screenshot` do there.
- Linux builds GDK key events and hands them to `gtk_main_do_event`, the function GDK hands every real event to.
- Linux first sends the window a focus-in event when it is not active, as a user's click on the window does.
- Linux and macOS also press and release each modifier key around the key, as a keyboard does.
- The key's physical key and the extra Shift it needs (Plus, `?`) come from the keyboard layout in use on each platform.
- Windows injects the key with the DevTools protocol's `Input.dispatchKeyEvent` (see Open questions 1).
- MacOS makes the app active and the window key when they are not, then posts the events to the application's queue.
- The new Ziggy scenario is `smoke-tests/desktop-only/28-zoom-keys`.
- The template and both examples get a `hello-action-shortcut` scenario that presses the template action's shortcut.
- Photosphere gets scenario `67-shortcut-keys`, which presses Ctrl+N and Ctrl+O.
- `press_key` is added to every `smoke-tests/lib/common.sh` (Ziggy, the template, both examples).
- The upgrade note goes under a `## v0.0.24` heading.

## Open questions

1. **How the Windows native app presses a key.** A user's key reaches WebView2's browser process, which raises `AcceleratorKeyPressed` in the native app (`acceleratorInvoke`, `packages/ziggy/native/windows/src/lib/native-app.zig` line 1622). That handler reads Control, Shift and Alt from `GetKeyState` in the native app's own process (`heldModifiers`, line 963), not from the event.
    - Option A: `SendInput`, after `SetForegroundWindow` on the app's window. This is the full system path. It needs the window in front and holding the keyboard, and the keyboard is shared by the whole desktop, so two runs on one Windows machine take it from each other. That breaks Ziggy's rule that every test survives running beside another copy of itself. CI runs Windows scenarios one after another.
    - Option B: `ICoreWebView2::CallDevToolsProtocolMethod` with `Input.dispatchKeyEvent` (already used for paste, line 1356). It reaches only this app's web view, so runs cannot collide. It enters Chromium below the system, so `GetKeyState` in the native app never sees the modifiers: today's `acceleratorInvoke` cannot match a Ctrl shortcut from it, and whether `AcceleratorKeyPressed` fires for it at all has not been checked.
    - Recommendation: B, if `plan-text-boxes-keep-their-keys.md` moves shortcut matching into the frontend's JavaScript (then the DOM `keydown` is the path a user's key takes, and B reaches it with the modifiers set). A, if that plan keeps native matching on Windows. Step 7 is written for B. For A, step 7 is replaced by: `pressKey` calls `SetForegroundWindow(native_app.window)` and `controller.MoveFocus(PROGRAMMATIC)`, then one `SendInput` call with the modifier downs, the key down and up (`KEYBDINPUT` with `wVk` from `VkKeyScanExW` for character keys and `accelerator_lib` for named keys) and the modifier ups, and replies once a posted `WM_ZIGGY_KEY_PRESS_DONE` message comes back through the message loop after them.

2. **Who adds the Ctrl+= assertion.** ziggy-updates.md says Ctrl+= should also zoom in. From the code: on Windows, `bindingFor` treats Plus as Shift-optional (`accelerator.zig` line 131), so Ctrl+= already zooms; on Linux the accelerator is `GDK_KEY_plus` (`addAccelerator`, line 680), and Ctrl+= gives `GDK_KEY_equal`, so it does not. None of the nine plan names claims that item.
    - Option A: this plan also makes Ctrl+= zoom in on every desktop platform and presses it in `28-zoom-keys`.
    - Option B: the plan that adds the zoom keys to the action list adds Ctrl+= and its press in `28-zoom-keys`.
    - Recommendation: B, so this plan stays a test hook and changes no shortcut. Until then `28-zoom-keys` presses only the shortcuts the test app declares.

## Overview

Smoke tests can choose a menu item (`menu`) but cannot press a key, so nothing tests that a shortcut works for a user: Ziggy's `12-menu-view` chooses the zoom items and never presses Ctrl+Plus. This plan adds a remote control command, `press-key`, that has the native app deliver a key press to its own window at the point the platform's real key events enter the app, so the press takes the same path a user's does and a broken shortcut fails the test. It acts only when the app is started with `--remote-control`, like every remote control command. ziggy-updates.md lists this command ("Key press test command"), which is the human's request for this test hook, as Ziggy's `CLAUDE.md` requires. It is used here by a Ziggy scenario that presses the zoom keys, by a template and example scenario that presses an action's shortcut and by a Photosphere scenario that presses Ctrl+N and Ctrl+O. `plan-text-boxes-keep-their-keys.md` and `plan-question-mark-shortcut.md` use it for the arrow keys, Enter, Escape and `?`.

## Issues

## Steps

All paths below are relative to `/home/ash/projects/photosphere/`. Ziggy's `remote-control.zig` and friends are already in place: `ziggy/docs/plans/new/plan-remote-control.md` is implemented (`packages/ziggy/core/src/lib/remote-control.zig`, `tools/remote-control-server`, `--remote-control` in every native app). Before changing Ziggy, check the pre-commit hook is installed as Ziggy's `CLAUDE.md` says.

### Ziggy repository (`ziggy/`)

1. Add the `key-press` call and the `has_key_press` flag.
    - `packages/ziggy/core/src/lib/native-message.zig`: add `key_press: []const u8` to `Call` (after `screenshot`, comment: press and release the key, a shortcut's text, as a user does; the result is empty). Add `key: ?[]const u8 = null` to `Wire`. `encode`: `.key_press => |key| wire.key = key`. `parse`: type `"key-press"` gives `.key_press = wire.key orelse return error.InvalidCall`. `typeName` gives `"key-press"`.
    - `packages/ziggy/core/src/lib/ziggy.h`: add `bool has_key_press;` after `has_screenshot` (line 50), commented "Whether the native app does "key-press" calls. False on a platform with no shortcuts. Used only by the remote control connection." Add `{"type":"key-press","key":"CmdOrCtrl+Plus"}` to the list of calls (after `screenshot`, near line 95): press and release the key, written as a shortcut, by the path a user's key press takes into the native app; the result is empty.
    - `packages/ziggy/core/src/lib/types.zig`: add `has_key_press: bool` after `has_screenshot` (line 61), with the same comment.
    - `packages/ziggy/core/src/lib/jni.zig` (the `types.ZiggyConfig` literal, line 338): `.has_key_press = false`.
    - `packages/ziggy/core/src/lib/fake-native-app.zig`: `.has_key_press = true` beside `.has_screenshot` (line 167); record each `key_press` call's key, one per line, in a `pressed_keys` list beside `screenshot_paths`, answered by a new request `"pressed-keys"` and read with `pub fn pressedKeys(io, allocator) ![]u8`, as `screenshotPaths` is; `defaultResult` gives `key_press` success with empty text, and failure with the reason `"no such key"` when the key is `"F24"`, so a test can see a native failure come back.
    - New `packages/ziggy/core/src/test/native-message.test.zig` (see Unit Tests).
    - `mise exec -C ziggy -- zig build test --summary all` passes.

2. Handle `press-key` in the remote control connection.
    - `packages/ziggy/core/src/lib/remote-control.zig`: add `has_key_press: bool` to `NativeAccess` (line 251) and `.has_key_press = config.has_key_press` in `RemoteControl.start` (line 122). Import `shortcut.zig`.
    - In `Connection.handleLine`, after the `screenshot` block (line 490), add `press-key`, commented: presses a key as a user does, through the native app, so the press takes the path a real one takes and a shortcut that is broken for a user fails. The steps: `key` must be a string, else `InvalidCommand`; `shortcut.parse(key)` must succeed, else reply `{"error":"InvalidKey","key":"<key>"}`; `!native.has_key_press` replies `NativeCallMissing`; `waitForUi`; `native.app.call(io, arena, .{ .key_press = key }, .{ .queue = &self.replies, .call_id = 0 })`; take the reply from `self.replies` and decode it with `worker_messages.INativeAppResponseMessage`, exactly as the screenshot block does; an error becomes `{"error":"<reason>"}`, success `{"ok":true}`.
    - Update the file's top comment (line 8) to list `press-key` among the commands the native app does.
    - `mise exec -C ziggy -- zig build test --summary all` passes, with the new tests in `remote-control.test.zig`.

3. Linux key helpers.
    - `packages/ziggy/native/linux/src/lib/menu-keys.zig`: add `pub fn gdkModifierKeyNames(core_modifiers: u32) ModifierKeys`, where `ModifierKeys` holds up to four GDK key names, in the order a keyboard presses them: `Control_L`, `Shift_L`, `Alt_L`, `Super_L` for the bits set. Add `pub fn gdkModifierFor(name: []const u8) c_uint` giving the GDK mask each of those keys sets.
    - Tests in `packages/ziggy/native/linux/src/test/menu-keys.test.zig` (see Unit Tests). `mise exec -C ziggy -- zig build test --summary all` passes.

4. Linux native app: press the key.
    - `packages/ziggy/native/linux/src/lib/gtk.zig`: declare, from GTK 3.24's `gdk/gdkevents.h`, `gdkkeys.h`, `gdkdisplay.h`, `gdkseat.h` and `gtkmain.h` (the file's rule: only what is used, each checked against the library's header documentation): `GdkEventKey` and `GdkEventFocus` as `extern struct`s in the header's field order (`type`, `window`, `send_event`, then for keys `time`, `state`, `keyval`, `length`, `string`, `hardware_keycode`, `group`, `is_modifier` as a one-bit field in a `c_uint`; for focus `in`), `GdkKeymapKey` (`keycode`, `group`, `level`), the event type values `GDK_KEY_PRESS` (8), `GDK_KEY_RELEASE` (9) and `GDK_FOCUS_CHANGE` (12), and `gdk_event_new`, `gdk_event_free`, `gdk_event_set_device`, `gtk_widget_get_window`, `gdk_display_get_default`, `gdk_display_get_default_seat`, `gdk_seat_get_keyboard`, `gdk_keymap_get_for_display`, `gdk_keymap_get_entries_for_keyval`, `g_free`, `g_object_ref`, `g_strdup`, `gtk_main_do_event` and `gtk_window_is_active` (any not already declared).
    - `packages/ziggy/native/linux/src/lib/native-app.zig`: set `config.has_key_press = true` beside `has_screenshot` (line 270). In `doCall` (line 480) add `.key_press => |key| pressKey(native_app, reply, key)`.
    - New `fn pressKey(native_app: *NativeApp, reply: u64, key: []const u8) void`, commented as the remote control's key press. It parses with `parseGdkShortcut` (a failure is `sendResult` not ok with the shortcut's text). It finds the key on the keyboard with `gdk_keymap_get_entries_for_keyval` on the default display's keymap, taking the entry in group 0 with the lowest level; level 1 adds `GDK_SHIFT_MASK` to the state, as the layout needs Shift for that character; no entry is a failure `"the keyboard has no key for <key>"`. When `gtk_window_is_active(window)` is false it first hands `gtk_main_do_event` a `GDK_FOCUS_CHANGE` event with `in = 1` on the window's `GdkWindow`. Then, through `gtk_main_do_event`, in order: a key press for each modifier key from `gdkModifierKeyNames` (with the state of the modifiers already down), the key's press and release (with the full state), and the modifier releases in reverse. Every key event has `window` set to a reference of the window's `GdkWindow`, `send_event = 0`, `time = 0` (`GDK_CURRENT_TIME`), the keyval and the entry's keycode and group, `string = g_strdup("")`, and the default seat's keyboard set with `gdk_event_set_device`, and is freed with `gdk_event_free`. Then `sendResult(native_app, reply, true, "")`.
    - `mise exec -C ziggy -- zig build` and `mise exec -C ziggy -- zig build test --summary all` pass.

5. Smoke test helper and the zoom keys scenario.
    - `smoke-tests/lib/common.sh`: after `choose_menu_item` (line 312), add `press_key`: "Presses a key as a user does, through the native app, so a shortcut that is broken for a user fails. The key is written as a shortcut, such as CmdOrCtrl+Plus. Usage: press_key <key>", sending `{"command":"press-key","key":"$1"}` and failing with the reply unless `.ok` is true, as `choose_menu_item` does.
    - New `smoke-tests/desktop-only/28-zoom-keys/test.sh`, after `12-menu-view`'s pattern: `start_test_app`, `normal="$(viewport_size)"`, then `press_key CmdOrCtrl+Plus`, `wait_for_viewport_other_than "$normal"`, `press_key CmdOrCtrl+0`, `wait_for_viewport "$normal"`, `press_key CmdOrCtrl+Minus`, `wait_for_viewport_other_than "$normal"`, `press_key CmdOrCtrl+0`, `wait_for_viewport "$normal"`. Its comment says the test app's View menu declares these shortcuts (`apps/ziggy-test-app` menu) and the keys go through the native app's key handling. When a sibling plan has already taken the number 28 in `desktop-only`, take the next free number.
    - Run `mise exec -C ziggy -- bun run test:smoke -- 28` and `mise exec -C ziggy -- bun run test:smoke -- 12` on Linux; both pass. A failure of the press is a bug in the key press or in the shortcut: find the cause and fix it.

6. MacOS native app.
    - `packages/ziggy/native/macos/Sources/ZiggyNativeMacOS/ZiggyBridge.swift`: `config.has_key_press = true` beside `has_screenshot` (line 219). In `doCall` (line 327) add `case "key-press"`: read `key`, else `ZiggyBridge.fail`; call `ZiggyKeyPress.press(key, window: window) { failure in ... finishCall(...) }` as `screenshot` does.
    - New `packages/ziggy/native/macos/Sources/ZiggyNativeMacOS/ZiggyKeyPress.swift`, with a top comment. `press` parses with `ZiggyMenu.parseShortcut(key, owner: "The key press")`. The key code: for the named keys with no character (`Up`, `Down`, `Left`, `Right`, `Home`, `End`, `PageUp`, `PageDown`, `Delete`, `Backspace`, `Enter`, `Tab`, `Escape`, `Space`, `F1` to `F20`) a table of Carbon's `kVK_` constants (`import Carbon.HIToolbox`); for a character key (a letter, a digit, Plus, Minus, Equal and later `?`) the key code whose character in the current layout (`TISCopyCurrentKeyboardLayoutInputSource`, `kTISPropertyUnicodeKeyLayoutData`, `UCKeyTranslate`) is the key's character without Shift, else with Shift, which adds `.shift`. No key code is a failure naming the key. When `NSApp.isActive` is false or the window is not key, `NSApp.activate(ignoringOtherApps: true)` and `window.makeKeyAndOrderFront(nil)`. Then `NSApp.postEvent(_:atStart: false)` for: a `.flagsChanged` event per modifier going down, the `.keyDown` and `.keyUp` (`NSEvent.keyEvent(with:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:)`, `windowNumber` the app window's, characters from `UCKeyTranslate` with and without the modifiers), the modifiers going up, and last an `.applicationDefined` event (subtype a constant of this file). A local monitor for `.applicationDefined` installed for the press sees that event come through the queue after the others, removes itself and calls the completion with no failure. Uses only APIs available on macOS 12.
    - `Package.swift` needs no change: the `ZiggyNativeMacOS` target takes every file in `packages/ziggy/native/macos/Sources/ZiggyNativeMacOS`.    - Runs only on a Mac: the MacOS smoke job is CI-only for this machine.

7. Windows native app (Option B of Open questions 1).
    - `packages/ziggy/native/windows/src/lib/accelerator.zig`: add `pub fn keyEventParams(buffer: []u8, kind: KeyEventKind, binding: Binding, key_name: []const u8, layout_shift: bool) ![]const u8`, giving the JSON parameters of `Input.dispatchKeyEvent`: `type` (`rawKeyDown`, `char` or `keyUp`), `modifiers` (DevTools bits: Alt 1, Ctrl 2, Meta 4, Shift 8, with Shift added when `layout_shift`), `windowsVirtualKeyCode` (`binding.virtual_key`), `key` and `code` (the DOM names for the key: `"+"` and `"Equal"` for Plus, `"ArrowUp"` and `"ArrowUp"` for Up and so on, a table beside `named_keys`) and, for `char`, `text`.
    - `packages/ziggy/native/windows/src/lib/native-app.zig`: `config.has_key_press = true` (line 899). `doCall` (line 795): `.key_press => |key| pressKey(native_app, reply, key)`. `pressKey` parses with `parseShortcut` and `shortcutBinding` (lines 1018 and 1031), finds whether the layout needs Shift with `VkKeyScanExW` for a character key, and sends `rawKeyDown`, then `char` when the key types a character, then `keyUp`, each through `CallDevToolsProtocolMethod` on the web view, the next sent from the completion of the one before, with a new `key_press_handler: DevToolsCallHandler` beside `paste_handler` (line 274, set up in `initHandlers` beside it, line 434) and the reply id kept on `NativeApp` while the press is in flight. A failed call gives `sendResult` not ok with `"Input.dispatchKeyEvent failed, HRESULT <n>"`; the last completion gives success.
    - Test in `packages/ziggy/native/windows/src/test/accelerator.test.zig` (see Unit Tests). `mise exec -C ziggy -- zig build test --summary all` builds and runs the Windows tests where the build runs them; the Windows smoke job is CI-only for this machine.

8. The template's helper and scenario.
    - `apps/ziggy-template/smoke-tests/lib/common.sh`: add `press_key` after `choose_menu_item` (line 232), the same as step 5.
    - New `apps/ziggy-template/smoke-tests/desktop-only/hello-shortcut/test.sh`, with the "Hello world example: change it into your own smoke test, or delete it." header the other template scenarios carry: `start_test_app`, `press_key CmdOrCtrl+Shift+H`, `wait_for_text log "Hello from an action" 30`. It starts its own app, so `hello-menu`'s line cannot be the one it finds.
    - `mise exec -C ziggy/apps/ziggy-template -- bun run test:smoke` on Linux passes, every scenario.

### Example repositories

Make every change in this section in `ziggy-example-vite/` and again in `ziggy-example-rsbuild/`. Each builds against the local Ziggy with Zig's `--fork=../ziggy` (it matches the `ziggy` dependency in `build.zig.zon`). `build.zig.zon` and the `ziggy` tag in `package.json` are not changed here: they move to the new tag when Ziggy is released, which is outside this plan.

9. Add the helper and the scenario.
    - `smoke-tests/lib/common.sh`: add `press_key` after `choose_menu_item` (line 232), the same as step 5.
    - New `smoke-tests/hello-action-shortcut/test.sh`, after `hello-action-menu/test.sh`: on `linux`, `windows` and `macos` it runs `start_test_app`, `press_key CmdOrCtrl+Shift+H` and `wait_for_text action-output "Hello from an action" 30`; on a phone it checks nothing.
    - Build and run against the local Ziggy, from the example's directory: `mise exec -- bun run bundle:ui`, then `mise exec -- zig build ziggy-example-vite-linux --fork=../ziggy -Doptimize=ReleaseSafe --prefix "$(pwd)/tmp/local-ziggy/linux"` (`ziggy-example-rsbuild-linux` in the rsbuild example), then `ZIGGY_SMOKE_BUILD="$(pwd)/tmp/local-ziggy/linux" mise exec -- bun run test:smoke`. Every scenario passes. `mise exec -- zig build test --fork=../ziggy` and `mise exec -- bun run test` pass. `tmp/` is in each example's `.gitignore`.

### Photosphere repository (`photosphere/`)

Photosphere builds against the local Ziggy with `--fork=../ziggy`. Its `build.zig.zon` and the `ziggy` tag in `apps/photosphere-frontend/package.json` are not changed.

10. Press Photosphere's shortcuts.
    - Add `press_key <port> <key>` to `apps/photosphere-smoke-tests/lib/common.sh`, after `send_command` (line 653): "Presses a key as a user does, through the native app. The key is written as a shortcut, such as CmdOrCtrl+O." It runs `send_command "$1" press-key "{\"key\":\"$2\"}"`.
    - New `apps/photosphere-smoke-tests/67-shortcut-keys/test.sh`, after `61-desktop-menu/test.sh`: exits 77 on `android` and `ios` ("a phone has no shortcuts"); `start_app`, `wait_for_ready`, `press_key "$APP_PORT" CmdOrCtrl+N`, `wait_for_log "$TMP_DIR" "Create database dialog opened"`; `stop_app`, `start_app`, `wait_for_ready`, `press_key "$APP_PORT" CmdOrCtrl+O`, `wait_for_log "$TMP_DIR" "Open database dialog opened"`; `check_no_errors`. The comment says Ctrl+N is the File menu's New Database item (`packages-zig/photosphere-core/src/lib/menu.zig`) and Ctrl+O the `open-database` action (`actions.zig`). When a sibling plan has already taken 67, take the next free number.
    - Run against the local Ziggy, from `photosphere/`: `env -C apps/photosphere mise exec -- bun run bundle:ui --out-dir "$(pwd)/tmp/local-ziggy/page"`, `mise exec -- zig build photosphere-linux --fork=../ziggy -Dcpu=baseline -Doptimize=ReleaseSafe -Dstrip=false -Dui-directory=tmp/local-ziggy/page --prefix "$(pwd)/tmp/local-ziggy/linux"`, `mise exec -- zig build --fork=../ziggy -p "$(pwd)/tmp/local-ziggy/psi"`, then `PHOTOSPHERE_SMOKE_BUILD="$(pwd)/tmp/local-ziggy/linux" PHOTOSPHERE_SMOKE_PSI="$(pwd)/tmp/local-ziggy/psi/bin/psi" mise exec -- bun run test:ziggy -- 67` and the same with `-- 61`. Both pass. `mise exec -- zig build test --fork=../ziggy --summary all --test-timeout 20m` passes.

### Documentation

11. Write the documentation.
    - Ziggy `docs/user-guide/testing.md`, the table of "Commands Ziggy handles itself": add `{"command": "press-key", "key": "CmdOrCtrl+Plus"}`: presses and releases the key as a user does, through the native app, written in the shortcut syntax of [Menus](menus.md#keyboard-shortcuts); the reply comes once the native app has delivered the press; a key that does not parse gets `InvalidKey`; on a phone and in dev mode it is `NativeCallMissing`. Say how each desktop native app delivers it (Linux: GDK events into GTK's event dispatch; Windows: as step 7 settles it; MacOS: events posted to the application's queue).
    - Ziggy `docs/user-guide/actions.md`, "Testing actions": add the template's `hello-shortcut` scenario, which presses the action's shortcut with `press_key`.
    - Ziggy `smoke-tests/run.md` scenario list: add `28-zoom-keys`: pressing the zoom keys changes the size of the area the frontend is drawn in, and Ctrl+0 puts it back.
    - Ziggy `docs/upgrade-notes.md`: under `## v0.0.24` (add the heading above `## v0.0.23` when it is not there): "**New, and optional:** the remote control command `press-key` and the smoke test helper `press_key`. Copy `press_key` from the template's `smoke-tests/lib/common.sh` into the app's own to use it."
    - Ziggy `docs/glossary.md`: no change (no new term).
    - Photosphere: `apps/photosphere-smoke-tests/lib/common.md` line 11: add `press_key` after `send_command` in the list of helpers.

## Unit Tests

- `core/src/test/native-message.test.zig` (new): `encode` of `.{ .key_press = "CmdOrCtrl+Plus" }` gives `{"type":"key-press","key":"CmdOrCtrl+Plus"}`; `parse` of that gives the same call back; `parse` of `{"type":"key-press"}` is `error.InvalidCall`.
- `core/src/test/remote-control.test.zig`:
  - "the press-key command presses the key through the native app once the UI is listening": nothing pressed before `test-ui-ready`; then the reply is `{"ok":true}` and `pressedKeys` is `"CmdOrCtrl+Plus\n"`.
  - "the press-key command replies with the reason when the native app cannot press the key": key `F24` gives `{"error":"no such key"}`.
  - "the press-key command without a key is an invalid command": `{"command":"press-key"}` gives `InvalidCommand` and nothing pressed.
  - "a key that is not a shortcut is refused": `"key":"Ctrl+Nope"` gives `{"error":"InvalidKey","key":"Ctrl+Nope"}` and nothing pressed.
  - "the press-key command on a native app with no key press reports what is missing": `has_key_press = false` gives `NativeCallMissing`.
- `native/linux/src/test/menu-keys.test.zig`: `gdkModifierKeyNames` of Ctrl and Shift gives `Control_L`, `Shift_L` in that order, of none gives none, of all four gives all four in order; `gdkModifierFor` gives the GDK mask of each.
- `native/windows/src/test/accelerator.test.zig`: `keyEventParams` for Ctrl+Plus with layout Shift gives `rawKeyDown` with modifiers 10, the Equal key's virtual key code, `key` `"+"`, `code` `"Equal"`; for Up gives `"ArrowUp"` and modifiers 0; `char` carries `text`; a buffer too small is an error.
- Swift (`ZiggyKeyPress`) has no unit test target in Ziggy; it is covered by the MacOS smoke tests (CI-only).

## Smoke Tests

- Ziggy `smoke-tests/desktop-only/28-zoom-keys`: Ctrl+Plus, Ctrl+0, Ctrl+Minus and Ctrl+0 pressed through `press-key` change the frontend's area and put it back. Linux here; Windows and MacOS CI-only.
- Ziggy `12-menu-view` and every other scenario still pass.
- Template `desktop-only/hello-shortcut`: Ctrl+Shift+H runs the template's action.
- Both examples' `hello-action-shortcut`: the same, in each example.
- Photosphere `67-shortcut-keys`: Ctrl+N opens the Create Database dialog and Ctrl+O the Open Database dialog. `61-desktop-menu` still passes.

## Verify

- Ziggy: `mise exec -C ziggy -- zig build`, `mise exec -C ziggy -- zig build test --summary all`, `mise exec -C ziggy -- bun run compile` and `mise exec -C ziggy -- bun run test` exit 0. `mise exec -C ziggy -- bun run test:android-shell` exits 0 (the JNI config gained a field).
- Ziggy Linux smoke: `mise exec -C ziggy -- bun run test:smoke` passes every scenario, `28-zoom-keys` among them. Run a second copy of `bun run test:smoke -- 28` beside it; both pass.
- Template: `mise exec -C ziggy/apps/ziggy-template -- bun run test:smoke` passes on Linux.
- Each example: the commands of step 9 pass on Linux.
- Photosphere: the commands of step 10 pass on Linux, and `mise exec -- bun run test` passes.
- `bash -n` passes over every new or edited shell script.
- Android and iOS: `mise exec -C ziggy -- bun run test:smoke:android` and `test:smoke:ios` pass where a device or simulator is attached (the core and JNI changed); `press-key` is not called there.
- CI-only: the Windows and MacOS smoke jobs, which run `28-zoom-keys`, `hello-shortcut`, `hello-action-shortcut` and `67-shortcut-keys` on those platforms.

## Notes

- ziggy-updates.md lists "Key press test command", which is the human's request for this test hook. Like every remote control command it acts only when the app is started with `--remote-control`: the `press-key` command exists only on the remote control connection, which only starts then.
- The press enters each platform where real key events enter the app, so whatever handles shortcuts (GTK accelerators and the web view on Linux, AppKit key equivalents and the local key monitor in `ZiggyActionShortcuts.swift` on MacOS, today's native matching or JavaScript matching if `plan-text-boxes-keep-their-keys.md` moves it) sees it as it sees a user's. Calling `performAction` or `runAction` directly was rejected: that is what `menu` already does, and it skips the shortcut.
- System-wide injection (XTest, `xdotool`, a global `SendInput` on Linux or MacOS `CGEventPost`) was rejected: it needs the keyboard focus of the whole desktop, which breaks Ziggy's and Photosphere's rule that every test survives running beside another copy of itself, and Photosphere runs its scenarios in parallel.
- Not checked by reading code, and settled by the smoke tests of steps 5, 8, 9 and 10: that WebKitGTK takes a key event from `gtk_main_do_event` on a window whose focus came from a synthetic focus-in; that GTK's accelerator matching takes Ctrl with Shift and `plus` for a `Ctrl+plus` accelerator; that AppKit dispatches posted key events to the key window once the app is active. A failure in any of them is a bug to find and fix, never a reason to change the scenario.
- The GTK 3 development headers are not installed on this machine (only `gtk-4.0`); `gtk.zig` declares GTK by hand from the header documentation, which is how every declaration there is written.
- The key's text uses Ziggy's shortcut syntax, so `?` works in `press-key` once `plan-question-mark-shortcut.md` adds it to `shortcut.zig` and to each platform's key table. The MacOS character search needs no change for it.
- Typing text into a text box stays the frontend's `type` and `insert` commands; `press-key` is for keys a shortcut or a text box's own handling reacts to.
- Window targeting (`"window": 2`) is `plan-remote-control-window-targeting.md`'s; `press-key` presses in the app's one window and takes whatever that plan adds to every command.
- Ziggy's `CLAUDE.md` requires the examples to move to a released tag; that release is outside this plan, so the examples are tested here with `--fork=../ziggy`.
