# `?` as an action's shortcut

## Decisions not approved by a human

- `?` is matched in the frontend by Ziggy's injected script, not by any native app.
- The injected script sends the new `frontend-shortcut` system message, and the core runs the action that has the `?` shortcut.
- `?` is the only new key: no other punctuation key is added.
- A `?` shortcut takes no modifiers: `Ctrl+?`, `Shift+?` and the rest fail the build.
- Only an action (`ziggy.action.Action.shortcut`) can have `?`: a menu item's own `shortcut` of `?` fails the build.
- Two actions with the `?` shortcut fail the build.
- A native menu item that runs a `?` action shows no shortcut beside its label.
- The `?` shortcut does nothing on a phone, as every other shortcut there.
- A text box is a `textarea`, a `select`, an `input` of any type that takes typed text, or an element with `contenteditable`.
- A held-down `?` (a repeated key press) runs the action once.
- A key press that a page handler has already marked with `preventDefault` does not run the action.
- The test app gets a `show-help` action with the `?` shortcut and a `help-log` element, for the smoke test.
- The new smoke test is `smoke-tests/desktop-only/28-question-mark-shortcut`.
- Photosphere and both example repositories get no change.
- The zoom keys in the action list and Ctrl+= are left to another plan.

## Open questions

1. **Does a native menu item that runs a `?` action show `?` beside its label?** The native apps match a menu item's shortcut themselves (a GTK accelerator, a Win32 accelerator table and WebView2's `AcceleratorKeyPressed`, an AppKit key equivalent), and a native match of `?` would take every `?` before a text box gets it. Options: (a) the item shows no shortcut, and `window.ziggy.listActions()` still reports `?` (recommended: one way of matching `?` on every platform, and Graft's overlay lists shortcuts from `listActions`); (b) Linux and Windows show `?` as text only (`gtk_accel_label_set_accel`, the text after the tab) and macOS shows none; (c) the build refuses an `.action` item for an action whose shortcut is `?`. The plan below is written for (a).
2. **Should `?` take modifiers, or should other punctuation keys (`/`, `,`, `.`) work the same way?** Options: (a) only a bare `?` (recommended: the feature list asks for `?`, and a bare key is the case that has to step aside for a text box); (b) `?` with Ctrl, Alt or Cmd as well; (c) every printable character, matched by `KeyboardEvent.key`. The plan below is written for (a).
3. **Does `?` work on a phone with a hardware keyboard?** Today a phone registers no shortcut and `listActions` reports every shortcut there as null. Options: (a) no, the core ignores `frontend-shortcut` on a phone (recommended: it matches `listActions` and the guide's "no shortcuts" on iOS and Android); (b) yes, and `listActions` reports `?` on a phone too. The plan below is written for (a).

## Overview

Graft's shortcuts overlay opens and closes with `?` as a Ziggy action, and `?` must still type a question mark in a text box, the overlay's own search box included. Today `?` cannot be a shortcut at all: `shortcut.parse` (`packages/ziggy/core/src/lib/shortcut.zig`, `writeKey` lines 95 to 123) knows letters, digits, function keys and a list of named keys, so `"?"` fails with `UnknownKey` and `rejectInvalidActions` (`action.zig` line 42) stops the build. Writing it as `Shift+Slash` is no answer either: `/` is not a key name, `?` is Shift and `/` only on some layouts, and each native app matches shortcuts before the system web view sees the key. On Linux the GTK accelerator group added to the window (`native/linux/src/lib/native-app.zig`, `buildMenu` line 615, `addStandaloneActionShortcuts` line 722) takes the key first. On Windows the accelerator table (`buildAcceleratorTable` line 1043) and WebView2's `AcceleratorKeyPressed` (`acceleratorInvoke` line 1622) match by virtual key, and WebView2 never raises `AcceleratorKeyPressed` for a key that maps to a character with no Ctrl or Alt held (Microsoft's `ICoreWebView2Controller` reference: "A key is considered an accelerator if either of the following conditions are true. Ctrl or Alt is currently being held. The pressed key does not map to a character."), so `?` never reaches it. On macOS a menu item's key equivalent goes to AppKit, and `ZiggyActionShortcuts.swift` matches standalone shortcuts in a local key monitor on `charactersIgnoringModifiers` plus the modifier flags, where Shift+/ arrives as `?` with Shift held and so matches no Shift-less shortcut. In dev mode `dev-client.js` matches `KeyboardEvent.code`, and `browserKeyCode` (`dev-shortcuts.zig` line 173) has no code for `?`. Any native match of a bare `?` would also take every `?` typed into a text box. This plan makes `?` a key of the shortcut grammar that only an action can use, keeps it away from every native app, and matches it in Ziggy's injected script (`ziggy-inject.js`), which sees the key press in the system web view on every platform and in dev mode, knows whether a text box has the focus, and posts a new `frontend-shortcut` system message that the core turns into the action. `window.ziggy.listActions()` reports the shortcut as `?` with no change to its code, because `writeDisplayText` writes a one character key as it is. Custom actions already have shortcuts (`Action.shortcut`, the same grammar as a menu item's, registered whether or not the action is on the menu, reported by `listActions`), so the only gap for custom actions is the key itself. The work is in the `ziggy` repository; Photosphere and the example apps need no change.

## Issues

## Steps

### Ziggy repository (`/home/ash/projects/photosphere/ziggy`)

Before step 1, check the pre-commit hook as `ziggy/CLAUDE.md` requires: `$(git -C /home/ash/projects/photosphere/ziggy rev-parse --git-common-dir)/hooks/pre-commit` links to `.githooks/pre-commit`, else run `mise exec -C /home/ash/projects/photosphere/ziggy -- bun run install-hooks`.

1. Add `?` to the shortcut grammar. `packages/ziggy/core/src/lib/shortcut.zig`:
    - `writeKey` (lines 95 to 123): a key of exactly `?` writes `?` as the key name.
    - `parse` (lines 50 to 89): after `writeKey`, when the key is `?` and `result.modifiers` is not 0, fail with a new `ParseError` member `ModifierWithQuestionMark`. The build's existing messages (`action.zig` line 43, `menu.zig` line 225) print the error's name, so the reason reaches the developer.
    - Add `pub fn isFrontendKey(key: []const u8) bool`, true for `?` only, with a comment block: a frontend key is one the injected script matches in the system web view and that no native app registers, so a focused text box still receives it.
    - Update the file's top comment (lines 1 to 8) and the `key` field's comment (line 33) to name `?` and its rule.
    - `writeDisplayText` needs no change: a one character key is written as `std.ascii.toUpper` of it, which leaves `?` as `?` on every platform.
    - `packages/ziggy/core/src/lib/ziggy.h`: the `ziggy_accelerator.key` comment (lines 151 to 153) lists the key names; add `?` with "which a native app never receives".
    - Unit tests in `packages/ziggy/core/src/test/shortcut.test.zig` (see Unit Tests). `mise exec -C /home/ash/projects/photosphere/ziggy -- bun run test:zig` exits 0.

2. Keep `?` away from the native apps and dev mode's code matching, and check it at build time.
    - `packages/ziggy/core/src/lib/action.zig`, `rejectInvalidActions` (lines 27 to 53): fail the build, naming both actions, when two actions have the shortcut `?`.
    - `action.zig`, `standaloneActionShortcuts` (lines 71 to 88): skip an action whose parsed key `isFrontendKey`. Update its comment.
    - `packages/ziggy/core/src/lib/menu.zig`, `rejectInvalidMenuItem` (lines 223 to 227): when an item's own `shortcut` parses to a frontend key, fail the build with "ziggy.menu: the item \"<label>\" has the shortcut ?, which only an action can have."
    - `menu.zig`: add a private `fn nativeShortcut(comptime item: Item, comptime actions: []const action_lib.Action) ?[]const u8` that returns `menuItemShortcut(item, actions)`, or null when that parses to a frontend key. Use it in `menuItemEntries` (line 410) for the entry's `shortcut` and in `menuActionShortcuts` (line 483) for the shortcut it lists, so no native menu entry and no dev shortcut carries `?`. Leave `rejectInvalidMenu`'s duplicate checks (lines 140 to 163) on `menuItemShortcut`. Update the comments of `MenuEntry.shortcut` (line 350), `menuEntries` and `menuActionShortcuts`.
    - `packages/ziggy/core/src/lib/dev-shortcuts.zig` needs no change of its own: `devShortcuts` reads `menuActionShortcuts`, so `browserKeyCode` never sees `?`. Add a sentence to its top comment saying a frontend key is left to the injected script.
    - Unit tests in `core/src/test/action.test.zig`, `menu.test.zig` and a new `core/src/test/dev-shortcuts.test.zig` (`build.zig`'s test discovery, lines 502 to 560, compiles every file under `src/test`). `bun run test:zig` exits 0.

3. Add the `frontend-shortcut` system message to the core.
    - `packages/ziggy/core/src/lib/action.zig`: add `pub const FrontendShortcut = struct { action: []const u8, key: []const u8 }` (comment on each field) and `pub fn frontendShortcuts(comptime actions: []const Action) []const FrontendShortcut`, made at compile time like `standaloneActionShortcuts`: one entry for every action whose shortcut parses to a frontend key, whether or not it is on the menu.
    - `packages/ziggy/core/src/lib/app.zig`: add the field `frontend_shortcuts: []const action_lib.FrontendShortcut = &.{}` to `RegisteredApp` after `standalone_action_shortcuts` (line 44), with a comment, and set it in `App`'s returned struct beside `.standalone_action_shortcuts` (line 240) as `comptime action_lib.frontendShortcuts(actions)`.
    - `packages/ziggy/core/src/lib/system-messages/action.zig`: add `pub const FrontendShortcutRequest = struct { key: []const u8 }` and `pub fn frontendShortcut(frontend_shortcuts: []const action_lib.FrontendShortcut, services: services_lib.HandlerServices, io: std.Io, allocator: std.mem.Allocator, request: FrontendShortcutRequest) !DoneResponse`. On a phone (`services.isPhone()`) it returns at once, as a phone registers no shortcut. Otherwise it runs the action whose `key` equals `request.key` through `services.runAction`, as `menuAction` does for an action (`system-messages/menu.zig` line 47). A key no action has returns at once: the injected script posts every bare `?` pressed outside a text box, and an app without a `?` action has no use for it. Update the file's top comment.
    - `packages/ziggy/core/src/lib/system-messages.zig`: add `"frontend-shortcut"` to `names` (lines 47 to 56) and mention it in the comment of `action` (line 24).
    - `packages/ziggy/core/src/lib/core.zig`: give `runSystem` (line 1381) a parameter `frontend_shortcuts: []const action_lib.FrontendShortcut` after `app_actions`, pass `app.frontend_shortcuts` from its caller (line 1360), and add a branch after `list-actions` (line 1421) that parses `FrontendShortcutRequest` with `handlers_lib.parsePayload` and its `.invalid` case as `run-action` does (lines 1412 to 1419), and responds with `frontendShortcut`.
    - Unit tests in `core/src/test/dispatcher.test.zig`, `registration.test.zig` and `action.test.zig`, with the core's test app (`core/src/test/test-app.zig`, `actions` line 194) given a third action, `ask`, label `Ask`, shortcut `?`, with no menu item. Update every expectation that lists the test app's actions: the two `list-actions` tests (`dispatcher.test.zig` lines 502 to 531) gain `{"name":"ask","label":"Ask","shortcut":"?"}` on desktop and `"shortcut":null` on a phone, after `shortcut-only`. Find any other expectation with `grep -rn "shortcut-only" packages/ziggy/core/src/test` and update it the same way. `bun run test:zig` exits 0.

4. Match `?` in the injected script. `packages/ziggy/core/src/lib/ziggy-inject.js`:
    - Add `function isTextEntryTarget(element)`: true for a `TEXTAREA`, a `SELECT`, an element whose `isContentEditable` is true, and an `INPUT` whose `type` (lower case) is none of `button`, `checkbox`, `color`, `file`, `hidden`, `image`, `radio`, `range`, `reset` and `submit`. Check by `tagName` and properties, not `instanceof`, so the fake window of the unit tests works.
    - Add `function onKeyDown(event)` and register it beside the drop listener (line 269) with `window.addEventListener("keydown", onKeyDown, false)`, so a page's own handlers on the target run first. It posts `postSystem("frontend-shortcut", { key: "?" })` when `event.key === "?"`, `event.ctrlKey`, `event.altKey` and `event.metaKey` are false, `event.repeat`, `event.isComposing` and `event.defaultPrevented` are false, and `isTextEntryTarget(event.target)` is false. It never calls `preventDefault` or `stopPropagation`, so the page still receives the key. Matching `event.key` rather than `event.code` makes `?` work on every keyboard layout, whichever key and Shift state types it.
    - Update the top comment's list of what the script does to name the `frontend-shortcut` message.
    - When this step is implemented after `plan-text-boxes-keep-their-keys.md` and that plan has already put a keydown listener or a text box check into `ziggy-inject.js`, add the `?` case to that listener and use its text box check, keeping one listener and one check. When this step comes first, that plan builds on `onKeyDown` and `isTextEntryTarget`.
    - Unit tests in `packages/ziggy/frontend/src/test/ziggy-inject.test.ts`. `mise exec -C /home/ash/projects/photosphere/ziggy -- bun run test` and `bun run compile` exit 0.

5. Give the test app a `?` action and a smoke test that presses `?`. This step uses the key press remote control command and its smoke test helper from `plan-key-press-test-command.md`, which is implemented before this step. That command must press the key through the operating system's input to the native app, as a user does, so a focused text area receives the typed character; the scenario below is the check that it does.
    - `apps/ziggy-test-app/backend/src/lib/handlers.zig`, `actions` (lines 989 to 995): add `.{ .name = "show-help", .label = "Show Help", .shortcut = "?" }`, written over several lines as the file does, with no menu item. Update the comment above `actions` (lines 985 to 988).
    - `apps/ziggy-test-app/frontend/index.html`: add `<pre data-id="help-log"></pre>` after `action-result` (line 45).
    - `apps/ziggy-test-app/frontend/src/main.ts`: in `startActions` (line 559) register `show-help` with a named handler `showHelp` that appends the line `help` to `help-log`, with a comment block, so each run of the action is counted.
    - Add `smoke-tests/desktop-only/28-question-mark-shortcut/test.sh` (executable, `bash -n` clean, sourcing `../../lib/common.sh` as `13-menu-edit` does), with a top comment saying what it checks:
        1. `start_test_app`, `click list-actions` and `wait_for_text action-result "show-help Show Help ?"`, which checks `listActions` reports `?`.
        2. With the focus on no text box, press `?` with the key press helper and `wait_for_text help-log "help"`.
        3. `insert_text notes "a"` (which focuses the text area), press `?`, and `wait_for_value notes "a?"`.
        4. `click run-say-action` and `wait_for_text action-result "said by an action"`. The core handles the frontend's messages in the order they are posted and the injected script posts in the key press itself, so by now any action the press in step 3 ran has reached the page.
        5. Fail unless `count_in help-log "help"` prints `1`.
    - `apps/ziggy-test-app/README.md` line 17: add that `?` runs an action anywhere but in a text box.
    - `mise exec -C /home/ash/projects/photosphere/ziggy -- bun run compile:zig`, `bun run test`, `bun run test:smoke -- 28-question-mark-shortcut` and `bun run test:smoke -- 27-actions` exit 0, then the whole `bun run test:smoke`.

6. Run the mobile suites the core change needs (`ziggy/CLAUDE.md`: a core change is not tested until the mobile suites run). On Linux: `bun run test:zig:android` and `bun run test:smoke:android`. On macOS: `bun run test:zig:ios` and `bun run test:smoke:ios`. Each exits 0.

7. Write the documentation.
    - `docs/user-guide/menus.md`, "Keyboard shortcuts" (lines 200 to 207): add `?` to the keys, with its rules: only an action's shortcut can be `?`, it takes no modifiers, it works on every keyboard layout, it does nothing while a text box has the focus, so the text box gets the question mark, and a menu item that runs the action shows no shortcut.
    - `docs/user-guide/actions.md`: in "Running an action" (line 66) and "Listing the actions" (line 88), say `?` is a shortcut an action can have and that `listActions` reports it as `?`.
    - `docs/development/architecture.md`: add a `frontend-shortcut` row to the system messages table (near line 108), and in the actions section (line 146) say that the desktop native apps register every action shortcut but `?`, which the injected script matches.
    - `docs/upgrade-notes.md`: under the next version's heading (add `## v0.0.24` at the top when it is missing), a line: "**New, and optional:** an action's shortcut can be `?` (see [Menus](user-guide/menus.md#keyboard-shortcuts))." An app needs no change.
    - `mise exec -C /home/ash/projects/photosphere/ziggy -- bun run diagrams` only if a diagram source changed; none is expected.

### Photosphere repository

No change: Photosphere declares no `?` shortcut (`packages-zig/photosphere-core/src/lib/actions.zig`), the change adds no member to `window.ziggy`, so its fake bridge (`apps/photosphere-frontend/src/test/fake-ziggy.ts`) is unaffected, and it takes the change with its next move to a Ziggy version.

### ziggy-example-vite and ziggy-example-rsbuild repositories

No change: the template is unchanged by this plan, so a move to the next Ziggy version carries over no change for `?`.

## Unit Tests

- `core/src/test/shortcut.test.zig`: `parse("?")` gives key `?` and modifiers 0; `parse` of `Ctrl+?`, `Shift+?` and `CmdOrCtrl+?` fails with `ModifierWithQuestionMark`; `isFrontendKey` is true for `?` and false for `a`, `f1` and `plus`; `writeDisplayText` of `?` is `?` on macOS, Linux and Windows.
- `core/src/test/action.test.zig`: `standaloneActionShortcuts` leaves out an action with `?` and keeps the others; `frontendShortcuts` lists every action with `?`, on the menu or not, and is empty for actions without one; `rejectInvalidActions` accepts one action with `?`.
- `core/src/test/menu.test.zig`: `menuEntries` gives a null shortcut for an `.action` item whose action's shortcut is `?`; `menuActionShortcuts` leaves out a `?` action, on the menu and off it.
- `core/src/test/dev-shortcuts.test.zig` (new): `devShortcuts` of a menu and actions that include a `?` action lists the others with their codes and leaves out the `?` action.
- `core/src/test/dispatcher.test.zig`: `frontend-shortcut` with `{"key":"?"}` sends the frontend the `action` system event for `ask`; with a key no action has, it sends no action event (the next message sent is answered with no action event before it); on a phone it sends none; a payload with no `key` is reported as invalid data, as for `run-action`; the two `list-actions` tests include `ask` (step 3).
- `core/src/test/registration.test.zig`: the "every system message" test (line 146) includes `frontend-shortcut`.
- `frontend/src/test/ziggy-inject.test.ts`: a `?` keydown on the body posts `{"kind":"system","name":"frontend-shortcut","data":{"key":"?"}}`; it posts nothing for a target that is a `TEXTAREA`, a `SELECT`, a text `INPUT`, a search `INPUT` or a `contenteditable` element; it posts for a checkbox `INPUT` and a `BUTTON`; it posts nothing when Ctrl, Alt or Meta is held, when `repeat` or `isComposing` is true, when `defaultPrevented` is true, or for a `/` key press; it never calls `preventDefault`.
- `apps/ziggy-test-app/frontend/src/test/menu-actions.test.ts` needs no new test: `showHelp` is a two-line handler in `main.ts`, covered by smoke test 28.

## Smoke Tests

- New `smoke-tests/desktop-only/28-question-mark-shortcut` (step 5): `listActions` reports `?`; `?` runs the action when no text box has the focus; `?` in a focused text area types a question mark and does not run the action. It runs on Linux, Windows and macOS through `bun run test:smoke`.
- Existing `smoke-tests/27-actions` still passes with the extra action in the list.
- Every scenario of `bun run test:smoke` and `bun run test:smoke:android` passes (the Android run on Linux, the iOS run `bun run test:smoke:ios` on macOS), showing the injected script's new listener breaks no other key handling.

## Verify

- `mise exec -C /home/ash/projects/photosphere/ziggy -- bun run compile`, `bun run compile:zig`, `bun run test:zig` and `bun run test` exit 0.
- `bash -n smoke-tests/desktop-only/28-question-mark-shortcut/test.sh` exits 0 and the file is executable.
- `bun run test:smoke` exits 0 on the machine's desktop platform, with scenario 28 among those run.
- On Linux, `bun run test:zig:android` and `bun run test:smoke:android` exit 0. On macOS, `bun run test:zig:ios` and `bun run test:smoke:ios` exit 0.
- `grep -rn '"?"' packages/ziggy/native` prints no line, so no native app names the key.
- CI-only: the Windows and macOS runs of scenario 28 on the platforms the machine is not.

## Notes

- Ordering: `plan-key-press-test-command.md` is implemented before step 5, which uses its key press command and helper. Steps 1 to 4 do not need it.
- Fit with `plan-text-boxes-keep-their-keys.md`: both plans need the injected script to know whether a text box has the focus. Whichever lands first adds the keydown listener and the text box check to `ziggy-inject.js`; the second extends them (step 4). This plan does not move any other shortcut out of the native apps.
- The `frontend-shortcut` message names the key, not the action, so the injected script needs no list of shortcuts and posts no message when it loads. A message at load would shift the ids and the `posted` indices every existing test in `ziggy-inject.test.ts` asserts, and could reach a native app before its core is ready.
- The injected script runs in the system web view on every platform and in dev mode (the dev backend serves it at `/__ziggy/inject.js`), so one listener covers Linux, Windows, macOS and dev mode. In dev mode `dev-client.js` keeps matching the other shortcuts by `code`.
- `listActions` reports the shortcut through the existing `formatShortcut` (`system-messages/action.zig` lines 91 to 98); a phone reports null, as for every shortcut.
- The other web view keys (reload, zoom, developer tools) all use Ctrl, Cmd or a function key, so a bare `?` clashes with none of them.
- The zoom keys in the action list and Ctrl+= zooming in, from the same section of the feature list, are not part of this plan.
- No Release step: the feature list and the brief ask for no commit, push, tag or release. No Clean up step: the plan deletes no file.
