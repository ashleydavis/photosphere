# Text boxes keep their keys

## Decisions not approved by a human

- A "typing shortcut" is any shortcut with no Ctrl, Alt or Cmd (Meta) modifier whose key is not a function key; Shift is allowed.
- Typing shortcuts are run by the inject script's `keydown` listener on every desktop platform and in dev mode, never by a native app.
- Shortcuts with Ctrl, Alt or Cmd, and function keys, stay with the native apps as they are today.
- The inject script's listener skips a key press whose `defaultPrevented` is set, so a page's own handler can keep a key.
- The inject script's listener runs a typing shortcut again on each auto-repeated key press.
- The inject script gets its typing shortcuts from a new system message, `list-typing-shortcuts`, which returns an empty list on a phone.
- `ziggy_dev_shortcuts_json` lists only the shortcuts a native app registers, so dev mode's script stands in for the native app and the inject script runs the typing shortcuts there too.
- A text box is a focused `textarea`, a `select`, an element that is `contentEditable`, or an `input` of any type but `button`, `checkbox`, `color`, `file`, `hidden`, `image`, `radio`, `range`, `reset` and `submit`.
- A `.standard` menu item with a typing shortcut fails the build.
- `ziggy_menu_entry` gains a `frontend_runs_shortcut` field that the core sets, so each native app shows such a shortcut without registering it.
- On Linux a typing shortcut on a menu item is shown with `gtk_accel_label_set_accel` and is not registered.
- On Windows a typing shortcut on a menu item is shown after the tab as now and has no binding.
- On macOS a menu item with a typing shortcut gets no key equivalent, so the menu does not show it (see Open questions).
- Windows turns WebView2's browser accelerator keys off (`put_AreBrowserAcceleratorKeysEnabled(FALSE)`), so the only keys that reload, zoom or open the developer tools are the app's own shortcuts.
- A shortcut written with `Plus` also runs on the same modifiers with `=`, on Linux, macOS and in dev mode (Windows already does this).
- `listActions` keeps showing only the shortcut as written (`Ctrl++`), with no second entry for `Ctrl+=`.
- Two shortcuts that differ only in `Plus` and `Equal` fail the build as the same shortcut.
- The checks go in the Ziggy test app (two new desktop-only smoke scenarios and new test app actions), not the template, so the example repositories need no change.

## Open questions

1. **How does macOS show a typing shortcut on a menu item without AppKit running it?** AppKit runs a menu item's key equivalent itself, so a typing shortcut set as a key equivalent would take the key from a focused text box. The options:
    - A: give the item no key equivalent. The shortcut still works (the inject script runs it) and `listActions` still lists it, but the macOS menu does not show it beside the item. The code for this is certain: an item with an empty key equivalent handles no key.
    - B: set the key equivalent and make `ZiggyMenu` the `NSMenuDelegate` of every menu, returning false from `menuHasKeyEquivalent(_:for:target:action:)` for a typing shortcut's key press. The menu shows the shortcut. Apple's page for that method could not be read while writing this plan, and returning true means `ZiggyMenu` has to find the item and return its target and action itself, which repeats AppKit's own matching for every other key press.
    - C: set the key equivalent and add a local key monitor that sends a typing shortcut's key press straight to the key window, skipping the menu. How `NSWindow.sendEvent` treats key equivalents was not checked.
    - Recommendation: A. It is the only option whose behaviour is known from the code, and a macOS app is unlikely to put a bare Escape or arrow key on its menu. Step 6 is written for A.

## Overview

Ziggy's docs say a shortcut works wherever the focus is, and the code does that on every desktop platform: the native app takes the key before the web view sees it. That is wrong for the keys a text box uses. An app whose action is on Escape, Enter or an arrow key takes that key from a text box the user is typing in. Per platform, today:

- Windows (`packages/ziggy/native/windows/src/lib/native-app.zig`, `acceleratorInvoke`, line 1622): WebView2's `AcceleratorKeyPressed` fires before the page sees a key. Microsoft's docs state that it fires for every key that "does not map to a character" and that "the `Escape` key is always considered an accelerator", so it fires for the arrow keys and Escape. For a key that matches a shortcut the code calls `put_Handled(1)` and runs the action, so the shortcut wins over the text box.
- Linux (`packages/ziggy/native/linux/src/lib/native-app.zig`, `buildMenu`, line 616, and `addStandaloneActionShortcuts`, line 722): every shortcut is a GTK accelerator on the window's `GtkAccelGroup`. GTK 3's window handles accelerators before it passes a key to the focused widget (the web view), so the shortcut is expected to win. GTK's source could not be fetched while writing this plan, so step 2 runs the new smoke scenario against the current code to observe it.
- macOS (`ZiggyMenu.swift`, `apply(accelerator:to:)`, line 197, and `ZiggyActionShortcuts.swift`, line 44): a menu item's shortcut is an AppKit key equivalent, and an action with no menu item is matched in a local key monitor (`NSEvent.addLocalMonitorForEvents`), which sees every key press before any window and returns `nil` for a match. The monitor wins over the text box for certain.
- Dev mode (`packages/ziggy/dev/src/lib/dev-client.js`, line 148): a `keydown` listener on `window` runs every shortcut and calls `preventDefault`, with no check of the focus, so it wins too.
- iOS and Android register no shortcut.

This plan moves the typing shortcuts (those with no Ctrl, Alt or Cmd, other than function keys) into one `keydown` listener in the inject script (`packages/ziggy/core/src/lib/ziggy-inject.js`), which runs on every platform and skips the key while a text box has the focus. The native apps stop registering typing shortcuts and keep every other shortcut. The same section of the feature list asks that shortcuts never clash with the web view's own keys and that `Ctrl+=` zoom in: Windows turns WebView2's browser accelerator keys off, and a `Plus` shortcut also runs on `=` on Linux, macOS and in dev mode (Windows' `accelerator.zig` already matches `Plus` on the `=` key with Shift optional, lines 61 and 131). The zoom items are already in `listActions` whenever the app's menu has them: `listActions` in `core/src/lib/system-messages/action.zig` (line 67) lists every `.standard` item with its shortcut, and the template's View menu has Zoom In, Zoom Out and Actual Size with `CmdOrCtrl+Plus`, `CmdOrCtrl+Minus` and `CmdOrCtrl+0`. This plan adds a smoke test that proves it.

## Issues

## Steps

### Ziggy repository (`ziggy/`)

Run every command in this section from `ziggy/` through `mise exec -C ziggy -- ...`. Before the first edit, check the pre-commit hook is installed as `ziggy/CLAUDE.md` requires (`bun run install-hooks` when it is not).

This plan's smoke scenarios press keys with the remote control key press command and its smoke test helper from `plan-key-press-test-command.md`. Implement that plan first. Below, the helper is written `press_key "<shortcut>"`, with the shortcut in Ziggy's own syntax (`Escape`, `CmdOrCtrl+Equal`, `CmdOrCtrl+Plus`, `F5`). Use the name and argument form that plan defines.

1. Add the test app's typing shortcuts and their handlers.
    - `apps/ziggy-test-app/backend/src/lib/handlers.zig`, `actions` (line 989): add `escape-action` ("Escape Action", shortcut `Escape`), `enter-action` ("Enter Action", shortcut `Enter`) and `down-action` ("Down Action", shortcut `Down`). Add an `.action` item for `down-action` to the Example menu after the `say-action` item (line 1146), so a typing shortcut on a menu item is covered; the other two have no menu item. Update the comment above `actions` (line 986).
    - `apps/ziggy-test-app/frontend/index.html`: add `<pre data-id="key-log"></pre>` after `action-result` (line 45).
    - `apps/ziggy-test-app/frontend/src/main.ts`, `startActions` (line 559): register a handler for each of the three actions that appends a line with the action's name to `key-log`. Update the comment above `startActions`.
    - `zig build` in `apps/ziggy-test-app` and `bun run compile` pass.

2. Add the smoke scenarios and run them against the current code.
    - `smoke-tests/desktop-only/<next unused number>-text-box-keys/test.sh`, with the comment block every scenario has: start the test app; with no text box focused, `press_key Escape`, `press_key Enter` and `press_key Down`, and `wait_for_text key-log` for each action's name; then `insert_text notes "hello"` (which focuses the text area), `press_key Escape`, `press_key Down`, `press_key Enter`, and `wait_for_value notes` until it holds `hello` and a newline; then `click run-say-action` and `wait_for_text action-result "said by an action"`; then check with `count_in key-log` that each of the three names appears exactly once. The button's `run-action` message reaches the core after any `menu-action` the text box's key presses could have posted, so a wrong run shows up before `action-result` changes. Then `click list-actions` and `wait_for_text action-result` for `down-action Down Action`.
    - `smoke-tests/desktop-only/<next unused number>-zoom-keys/test.sh`: start the test app and take `viewport_size`. For each of `CmdOrCtrl+Plus` and `CmdOrCtrl+Equal`: `press_key` it, `wait_for_viewport_other_than` the normal size, `choose_menu_item zoom-out`, `wait_for_viewport` the normal size (one step in and one step out, which fails when the web view also zoomed). Then `press_key CmdOrCtrl+Minus`, wait for another size, `press_key CmdOrCtrl+0`, wait for the normal size. Then `choose_menu_item start-short`, `wait_for_text output "hello from a short task"`, `press_key F5` (the test app has no F5 shortcut, and F5 reloads in WebView2 while its browser keys are on), `press_key CmdOrCtrl+Equal`, wait for the viewport to change and check `text_of output` still holds the task's line. Finally `click list-actions` and `wait_for_text action-result` for `zoom-in`, `zoom-out` and `zoom-reset`.
    - Run `bash -n` over both scripts. Run both on Linux with `bun run test:smoke -- <scenario name>` (the form `smoke-tests/run.md` gives for one scenario), capturing the output to `tmp/`. Record in this step which checks fail on the current code. These failures are what steps 3 to 8 fix.

3. Core: the typing shortcut rule and Plus as Equal. `packages/ziggy/core/src/lib/shortcut.zig`.
    - Add `pub fn isTypingKey(parsed: Shortcut) bool`: true when `modifiers` has none of `modifier_ctrl`, `modifier_alt` and `modifier_meta` and the key is not a function key. Comment block: a focused text box types or moves its cursor with such a key, so the frontend runs it and only while no text box has the focus.
    - Add `pub fn isSameKeyPress(first: Shortcut, second: Shortcut) bool`: equal modifiers and equal keys, counting `plus` and `equal` as one key, because `Plus` also runs on `=`.
    - Update the file's top comment.
    - Tests in `packages/ziggy/core/src/test/shortcut.test.zig` (see Unit Tests). `zig build test` passes.

4. Core: which shortcuts the frontend runs. 
    - `core/src/lib/menu.zig`, `rejectInvalidMenu` (line 130): compare shortcuts with `shortcut_lib.isSameKeyPress` on the parsed shortcuts instead of `std.mem.eql` on their text, at both comparisons (lines 142 and 160). In `rejectInvalidMenuItem` (line 171), a `.standard` item whose shortcut `isTypingKey` fails the build: `ziggy.menu: the item "<label>" runs a standard action and has the shortcut "<text>", which a text box types with. A standard action's shortcut needs Ctrl, Alt or Cmd, or is a function key.` Update both comment blocks.
    - `core/src/lib/menu.zig`, `MenuEntry` (line 340): add `frontend_runs_shortcut: bool`, after `shortcut`, with a comment: true when the item's shortcut is a typing shortcut, which the inject script runs, so the native app shows it and registers no key for it. Set it in `menuItemEntries` (line 405) and set it false for every other entry.
    - `core/src/lib/ziggy.h`, `ziggy_menu_entry` (line 165): add `bool frontend_runs_shortcut;` after `shortcut`, with the same comment, so the C struct matches the Zig `extern struct`.
    - `core/src/lib/action.zig`, `standaloneActionShortcuts` (line 172): leave out an action whose shortcut `isTypingKey`. Update its comment and the comment of `StandaloneActionShortcut`.
    - `core/src/lib/dev-shortcuts.zig`: rename `DevShortcut` to `BrowserShortcut` (a shortcut as a page's `keydown` listener matches it) and add the field `shiftOptional: bool`, true for a `plus` key, because `Plus` also runs on `=` with Shift held or not. `devShortcuts` (line 35) leaves out typing shortcuts. Add `pub fn typingShortcuts(comptime menu, comptime actions) []const BrowserShortcut`, the typing shortcuts of `menu_lib.menuActionShortcuts`, which the inject script runs. Update the file's top comment to cover both lists. Update the references in `core/src/lib/app.zig` and `core/src/lib/ziggy-api.zig`.
    - `core/src/lib/app.zig`, `RegisteredApp` (line 48): add `typing_shortcuts: []const dev_shortcuts.BrowserShortcut = &.{}` with its comment, set in `App` beside `dev_shortcuts_json` (line 242) to `comptime dev_shortcuts.typingShortcuts(definition.menu, actions)`.
    - `core/src/lib/system-messages/action.zig`: add `pub fn listTypingShortcuts(typing_shortcuts, services) []const BrowserShortcut`, which returns the list, or an empty one when `services.isPhone()`. Update the file's top comment.
    - `core/src/lib/system-messages.zig`: add `"list-typing-shortcuts"` to `names` (line 46) and to the comment of `action`. `core/src/lib/core.zig`, `runSystem` (line 1381): handle it beside `list-actions` (line 1421), passing the registered app's `typing_shortcuts`. Thread the list through the same path `app_actions` takes to `runSystem`.
    - `core/src/test/test-app.zig`, `actions` (line 194): add `typing-only` ("Typing Only", shortcut `Escape`) and update the comment above. Update the expected values that list the test app's actions and shortcuts, which now include it: the two `list-actions` tests in `core/src/test/dispatcher.test.zig` (lines 502 and 522) and the `standaloneActionShortcuts` test in `core/src/test/action.test.zig` (line 48), which must not list it.
    - Tests listed under Unit Tests. `zig build test` passes.

5. Inject script and dev script.
    - `packages/ziggy/core/src/lib/ziggy-inject.js`: when it runs, send `list-typing-shortcuts` with `invokeSystem` and keep the list (an error is logged with `postSystem("log", ...)` naming that typing shortcuts do not work in this page). Add a `keydown` listener on `window`, in the bubbling phase. It does nothing when `event.defaultPrevented` is set or `isTextBox(window.document.activeElement)` is true. Otherwise, for the first shortcut whose `code`, `ctrl`, `alt` and `meta` match the event and whose `shift` matches `event.shiftKey` (or `shiftOptional` is set), it calls `preventDefault` and posts the `menu-action` system message naming the shortcut's action, as `dev-client.js` does. Add `isTextBox(element)` as a named function with the rule given under Decisions. Comment each function.
    - `packages/ziggy/dev/src/lib/dev-client.js`, `findPressedShortcut` (line 136): match `shift` with `shiftOptional` as above. Update the comment at line 121: the list holds the shortcuts a desktop native app registers, and the inject script runs the typing shortcuts.
    - Tests in `packages/ziggy/frontend/src/test/ziggy-inject.test.ts` and `dev-client.test.ts` (see Unit Tests). `bun run compile` and `bun run test` pass.

6. Native apps.
    - Linux, `packages/ziggy/native/linux/src/lib/native-app.zig`, `buildMenu` (line 654): when `entry.frontend_runs_shortcut` is set, call a new `showShortcut(menu_item, text)` instead of `addAccelerator`. `showShortcut` parses with `parseGdkShortcut`, takes the item's child with `gtk_bin_get_child`, fails with an error naming the item when the child is not a `GtkAccelLabel` (`g_type_check_instance_is_a` with `gtk_accel_label_get_type()`) and calls `gtk_accel_label_set_accel` (GTK 3.6 and later), which only draws the shortcut. In `addAccelerator` (line 680) and `addStandaloneActionShortcuts` (line 722), when the key is `plus`, also register the `equal` key value with the same modifiers, with flags `0` for the menu item so the label still shows `+`, and with its own context and closure for a standalone shortcut. Update the comments of `buildMenu` (line 612) and the three functions.
    - Windows, `packages/ziggy/native/windows/src/lib/native-app.zig`, `appendMenuItem` (line 986): when `entry.frontend_runs_shortcut` is set, keep the shortcut in the item's text and leave `binding` null, so neither the accelerator table nor `acceleratorInvoke` takes the key. In the web view setup (line 938), query `ICoreWebView2Settings3` from the settings with `QueryInterface` and `IID_ICoreWebView2Settings3`, call `put_AreBrowserAcceleratorKeysEnabled(settings3, 0)` through `check`, and release it. Comment: WebView2's own reload, zoom, find, print and developer tools keys would act beside the app's shortcuts, so the app's menu is the only source of those keys. The Windows SDK the template downloads (1.0.3856.49) has the interface.
    - macOS, `packages/ziggy/native/macos/Sources/ZiggyNativeMacOS/ZiggyMenu.swift`: `nestedMenus` (line 69) records `entry.frontend_runs_shortcut` as `"frontendRunsShortcut"`; `makeItem` (line 190) calls `apply(accelerator:to:)` only when it is false. In `makeItem`, for an item whose shortcut's key is `plus`, also return a hidden alternate item with the key equivalent `=`, the same modifiers, target, action and represented object, `isHidden = true` and `allowsKeyEquivalentWhenHidden = true` (macOS 10.13 and later, inside Xcode 14.2's SDK); change `makeItem` to return the items to add and update its two callers (lines 108, 115 and 153). Update the file's top comment.
    - macOS, `ZiggyActionShortcuts.swift`, `matchingAction` (line 60): a shortcut whose key equivalent is `+` also matches the characters `=`. The core no longer lists typing shortcuts here (step 4). Update the file's top comment.
    - `zig build test` passes (the Linux and Windows native tests run there). `zig build` in `apps/ziggy-test-app` and `apps/ziggy-template` passes, and so does the Windows cross-build the template's `scripts/zig-packages.sh` makes. The Swift code builds only on a Mac: its build is CI-only.

7. Run the tests.
    - The two scenarios from step 2 on Linux, each alone, then `bun run test:smoke` (Linux, every scenario), with output captured to `tmp/`.
    - `bun run test:android-shell` and `bun run test:zig:android` (the core changed, and a phone must return an empty typing list), when `adb devices` lists a device in state `device` at that moment; otherwise they are CI-only for this run.
    - `bun run test:smoke:android` on the same condition.
    - Windows, macOS and iOS suites are CI-only on this machine.

8. Documentation.
    - `docs/user-guide/menus.md`: "Keyboard shortcuts" (line 200): replace line 207 with what a shortcut does now: a shortcut with Ctrl, Alt or Cmd, or a function key, works wherever the focus is; a typing shortcut (define it) runs only while no text box has the focus, so a focused text box keeps arrow keys, Enter and Escape; a page's own `keydown` handler that calls `preventDefault` keeps the key; a shortcut written with `Plus` also runs on `=`; a `.standard` item cannot have a typing shortcut. "On each platform" (lines 211 to 215): Windows turns WebView2's browser keys off, so the app's menu holds the only reload, zoom and developer tools keys; macOS shows no key equivalent for a typing shortcut on a menu item.
    - `docs/user-guide/actions.md` (lines 66 and 92 to 95): the same rule for an action's shortcut, linking to the menus section.
    - `docs/user-guide/dev-mode.md` (line 22) and `docs/development/dev-mode.md` (line 24): `/__ziggy/shortcuts` holds the shortcuts a native app registers; the inject script runs the typing shortcuts.
    - `docs/development/architecture.md`: add `list-typing-shortcuts` to the system message table (near line 108) and rewrite line 146 (each desktop native app registers every shortcut but the typing shortcuts, which the inject script runs).
    - `docs/glossary.md`: add "Typing shortcut".
    - `apps/ziggy-template/native/windows/README.md` (lines 14 and 15) and `apps/ziggy-template/native/macos/README.md` (line 23, which can now state that Command and `=` zooms in).
    - `docs/upgrade-notes.md`: add a `## v0.0.24` heading above `## v0.0.23` when it is not there, with lines for: a `.standard` item with a typing shortcut fails the build; two shortcuts that differ only in `Plus` and `Equal` fail the build; `ziggy_menu_entry` has `frontend_runs_shortcut`, which native code of the app's own reads; WebView2's browser keys are off on Windows, so an app that relied on F5 or Ctrl+F adds a menu item.
    - Follow `writing.md`. No count in any doc.

### Photosphere repository (`photosphere/`)

9. Build against the local Ziggy. Photosphere's menu (`packages-zig/photosphere-core/src/lib/menu.zig`) and actions (`actions.zig`) have only shortcuts with `CmdOrCtrl` or `F11`, so no code changes. From `photosphere/`, run `mise exec -C photosphere -- zig build --fork=../ziggy` and `mise exec -C photosphere -- zig build test --fork=../ziggy -Dcpu=baseline`, capturing the output to `tmp/`. Both pass. Photosphere moves to the Ziggy release that holds this change when it moves for the other plans of the same release.

### Example repositories

10. `ziggy-example-vite` and `ziggy-example-rsbuild`: no change. Both lock Ziggy to v0.0.23 and their menus and actions (copies of the template's) hold no typing shortcut and no `Equal` shortcut, so the next Ziggy version builds them unchanged. They move to the new tag when Ziggy is released, as `ziggy/CLAUDE.md` requires.

## Unit Tests

- `core/src/test/shortcut.test.zig`: `isTypingKey` is true for `Escape`, `Enter`, `Up`, `Down`, `Shift+Down`, `J` and `Plus`; false for `Ctrl+Escape`, `Alt+Down`, `Cmd+Enter`, `CmdOrCtrl+J`, `F5` and `Shift+F5`. `isSameKeyPress` is true for `CmdOrCtrl+Plus` and `CmdOrCtrl+Equal`, true for two equal shortcuts, false for different modifiers and false for different keys.
- `core/src/test/menu.test.zig`: `menuEntries` sets `frontend_runs_shortcut` for an `.action` item whose action's shortcut is `Down` and for a `.ui` item with `Escape`, and clears it for `CmdOrCtrl+Shift+H`, a separator and a menu.
- `core/src/test/action.test.zig`: `standaloneActionShortcuts` leaves out an action on `Escape` and keeps one on `CmdOrCtrl+Shift+O`.
- New `core/src/test/dev-shortcuts.test.zig`: `devShortcuts` leaves out typing shortcuts; `typingShortcuts` holds exactly the typing shortcuts of menu items and standalone actions, with `code` `Escape`, `ArrowDown` and `Enter`; `shiftOptional` is true for a `Plus` shortcut and false otherwise.
- `core/src/test/dispatcher.test.zig`: `list-typing-shortcuts` returns the test app's `typing-only` action with code `Escape`; on a phone it returns `[]`; the two `list-actions` tests include `typing-only`.
- `core/src/test/registration.test.zig` (line 146): add `list-typing-shortcuts` to the names checked.
- `frontend/src/test/ziggy-inject.test.ts`: the script sends `list-typing-shortcuts` when it runs; with the list returned, an `Escape` key press with `document.activeElement` on the body posts `menu-action` naming the action and calls `preventDefault`; the same press with a `textarea`, a text `input`, a `select` and a `contentEditable` element focused posts nothing and leaves the event alone; a `checkbox` input focused still runs it; a press with `defaultPrevented` set posts nothing; a key with Ctrl held that only matches without it posts nothing; a `Plus` shortcut runs with Shift held and without; a failed `list-typing-shortcuts` logs an error. `isTextBox` gets its own cases for every element kind in the rule.
- `frontend/src/test/dev-client.test.ts`: a shortcut with `shiftOptional` matches with and without Shift; one without it matches only its own Shift state.
- `native/linux/src/test/menu-keys.test.zig`: no new function there; `showShortcut` and the `equal` registration call GTK and are covered by the smoke scenarios.
- `native/windows/src/test/accelerator.test.zig`: unchanged functions; the null binding of a typing shortcut is covered by the smoke scenarios on Windows (CI-only here).

## Smoke Tests

- `smoke-tests/desktop-only/<n>-text-box-keys`: typing shortcuts run outside a text box, both on a menu item (`Down`) and standalone (`Escape`, `Enter`); inside the text area the same keys reach the text area (Enter adds a newline) and run no action; `listActions` lists the menu item's typing shortcut.
- `smoke-tests/desktop-only/<n>-zoom-keys`: `CmdOrCtrl+Plus` and `CmdOrCtrl+Equal` each zoom in by one step only; `CmdOrCtrl+Minus` zooms out; `CmdOrCtrl+0` resets; F5, which the app does not define, does not reload; `listActions` lists `zoom-in`, `zoom-out` and `zoom-reset`.
- Every existing scenario in `smoke-tests/` passes on Linux.

## Verify

- `zig build` and `zig build test` in `ziggy/` exit 0; `zig build` in `apps/ziggy-test-app` and `apps/ziggy-template` exits 0.
- `bun run compile` and `bun run test` in `ziggy/` exit 0.
- `bun run test:smoke` on Linux exits 0, with both new scenarios in it, and step 2 recorded them failing on the old code.
- `bun run test:android-shell`, `bun run test:zig:android` and `bun run test:smoke:android` exit 0 when a device is attached at that moment.
- In `photosphere/`, `zig build --fork=../ziggy` and `zig build test --fork=../ziggy -Dcpu=baseline` exit 0.
- `bash -n` passes over both new scenarios.
- `grep -rn "DevShortcut" packages/ziggy` prints no match.
- CI-only: the Windows, macOS and iOS smoke suites and the Swift build.

## Notes

- Windows behaviour today is confirmed from Microsoft's docs (https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2controller) and the code. macOS is certain for actions with no menu item (the local key monitor). Linux's GTK order and macOS key equivalents for menu items are inferred; step 2 observes Linux on this machine and the macOS run in CI covers the rest.
- WebView2's `AreBrowserAcceleratorKeysEnabled` keeps movement and editing keys (Home, End, Page Up, Page Down, Ctrl+X, Ctrl+C, Ctrl+V, Ctrl+A, Ctrl+Z) working, per https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2settings3, and has no effect on `AcceleratorKeyPressed`, so Ziggy's own shortcuts keep working.
- Ziggy's `toggle-devtools`, `reload` and zoom standard actions on Windows call WebView2's APIs (`put_ZoomFactor` at line 1327), not its browser keys, so turning the keys off leaves them working.
- Shortcuts a text box also uses with a modifier (Ctrl+Left, Alt+Left on macOS, Shift+arrows) are not typing shortcuts under this rule and still go to the native app. The feature list names arrow keys, Enter and Escape on their own.
- The `?` shortcut is `plan-question-mark-shortcut.md`. A `?` shortcut is a typing shortcut under this rule, so it runs through this plan's inject script listener and leaves a focused text box its question mark; that plan adds `?` to the parser and the key matching.
- A compile error cannot be unit tested in Zig, so the new build failures (a `.standard` item with a typing shortcut, `Plus` beside `Equal`) are checked once while implementing by building a scratch copy of the test app's menu with each, and are not kept as tests.
- The scenarios go in the test app, not the template, because the template's smoke tests are what the example repositories copy and those need no change.
- Docs review: the human chose no documentation review stop, so step 8 writes the documentation last.
