# Theme support in Ziggy with Photosphere moved onto it

## Decisions not approved by a human

- The theme setting is the key `theme` at the top level of the config file, with the values `light`, `dark` and `system`. A missing key means `system`.
- A config file whose `theme` holds any other value is logged as an error naming the value and the app runs with `system`.
- `--theme` sets the theme for that run only and is never written to the config file.
- A theme the app sets while `--theme` is in force replaces the override for the rest of the run and is written to the config file.
- A config reload while `--theme` is in force leaves the theme as `--theme` gave it.
- The core takes `--theme` out of the arguments before the app's `on_create` sees them.
- On Android `--theme` is the string Intent extra `ziggy.theme`, as `--remote-control` is `ziggy.remoteControl`.
- The iOS native app passes its command-line arguments to the core, as the macOS one does, so `--theme` works under `xcrun simctl launch`.
- The core resolves `system` to light or dark; the frontend is only ever given `light` or `dark` as the theme to draw.
- The native app reads the system theme and posts each change to the core as the system message `system-theme`.
- On Linux the system theme is the freedesktop portal's `org.freedesktop.appearance` `color-scheme` (1 is dark, anything else light), read and watched through GDBus.
- On Linux, when the portal does not answer, the system theme is light and the native app logs one line naming the failure.
- On Windows the system theme is the registry value `AppsUseLightTheme`, re-read on `WM_SETTINGCHANGE` with `ImmersiveColorSet`.
- On macOS the system theme is the `AppleInterfaceStyle` user default, re-read on the distributed notification `AppleInterfaceThemeChangedNotification`.
- On iOS the system theme is `UIScreen.main.traitCollection.userInterfaceStyle`, re-read when the app becomes active, so a scheduled change while the app stays in front is picked up at its next activation.
- On Android the system theme is the night bit of `Configuration.uiMode`, re-read in `onConfigurationChanged`, which each app's `MainActivity` forwards.
- The page gets the theme before its first script through a second document-start script the core writes (`window.__ziggyTheme = {...}`), which the native app puts in front of the inject script and replaces on every change.
- `window.ziggy` gains `getTheme()` (synchronous), `setTheme(setting)`, `onThemeChanged` and `removeThemeChangedListener`.
- The core sends the system event `theme-changed` with `{setting, theme}` whenever either changes.
- The core sends the native app the call `{"type":"theme","theme","background","script"}` whenever either changes. `ziggy_theme` gives the same JSON at start-up.
- The app declares the native background colour for each theme as the optional `ziggy.core.App` field `.backgrounds`, defaulting to white (`0xffffff`) and black (`0x000000`).
- Each native app paints the window and web view background with that colour. It also sets the platform's own dark chrome where one call does it: GTK's `gtk-application-prefer-dark-theme`, Windows `DWMWA_USE_IMMERSIVE_DARK_MODE`, macOS `NSApp.appearance` and iOS the window's `overrideUserInterfaceStyle`.
- The Android native app sets only background colours, not the status bar or navigation bar style.
- The Windows native app shows its window only once the core exists and the theme is applied, instead of before WebView2 starts.
- In dev mode the dev host serves the theme script at `/__ziggy/theme.js`, the browser's `prefers-color-scheme` is the system theme (posted by `dev-client.js`). The dev host ignores the native `theme` call.
- Ziggy's smoke tests and Photosphere's pass `--theme` from the environment variables `ZIGGY_THEME` and `PHOTOSPHERE_SMOKE_THEME`.
- The new Ziggy scenarios are `smoke-tests/28-theme` (every platform) and `smoke-tests/desktop-only/29-theme-screenshots`. Photosphere's is `apps/photosphere-smoke-tests/67-theme`.
- A theme screenshot test proves the theme changed the window by `cmp` finding the light and dark PNGs different.
- Photosphere's frontend logs `The theme is <theme> (setting <setting>).` each time it applies a theme. Its smoke test waits on that line.
- Photosphere drops `PHOTOSPHERE_THEME`, `env-theme.ts`, the `theme` query parameter, its own `theme` config key and its `theme-changed` app event.
- Photosphere's background colours are Joy's default `background.body` values (`#FFF` and `#000`).
- Photosphere takes Ziggy as a local path dependency in `build.zig.zon`, `apps/photosphere-frontend/package.json` and the Android `settings.gradle`; its Xcode projects stay on the version tag.
- The two example repositories are not changed by this plan.
- The upgrade notes go under a `## v0.0.24` heading in `docs/upgrade-notes.md`.
- Ziggy's guide gets a new page, `docs/user-guide/theme.md`.

## Open questions

1. **Where the theme key sits in the config file.** plan-config-and-state.md is being written at the same time and fixes the TOML layout of Ziggy's config file: whether Ziggy's own settings sit at the top level beside the app's or in a table of their own (such as `[ziggy]`). Options: (a) a top-level `theme = "dark"`; (b) `theme` inside a Ziggy table, `[ziggy]` then `theme = "dark"`. Recommendation: (a), because the user edits this file and `theme` is the name they look for; this plan is written for (a) and needs only the key path changed for (b).
2. **Building Photosphere's macOS and iOS apps against the local Ziggy.** Photosphere's Xcode projects take Ziggy's Swift package from GitHub by version tag and Xcode 14.2 (the version this project is locked to) has no local package reference in the project file. Options: (a) leave the Xcode projects on the tag, so Photosphere's macOS and iOS builds take the theme code when Ziggy is next released and Photosphere moves to that release; (b) replace the package reference with a local folder reference to `../ziggy` for this work. Recommendation: (a), because the macOS and iOS builds run only on a Mac and the move to a Ziggy release already changes these references; this plan is written for (a).

## Overview

Ziggy gains theme support: a theme setting (`light`, `dark` or `system`) stored as the `theme` key of the config file that plan-config-and-state.md adds, a `--theme` argument that overrides it for one run, OS integration on Linux, Windows, macOS, iOS and Android that reads the system theme and follows its changes, a `theme-changed` event the frontend handles, `window.ziggy.getTheme()` and `setTheme()` and no flash of the wrong theme at start-up. The native app paints the app's background colour for the theme before the page shows. The page reads the theme synchronously before its first script. A change made in another window or in an editor reaches a running app through the config reload of plan-config-reload.md. Ziggy owns the setting, the argument and the OS integration; the app owns how its pages look. Photosphere today keeps its own `theme` config key, passes it in the page's query, forces a theme with the build-time `PHOTOSPHERE_THEME` variable and lets MUI Joy follow `prefers-color-scheme` for `system`; this plan moves it onto Ziggy's theme. The plan depends on plan-config-and-state.md, which must be implemented first: it provides the config file, reading it on the core's main thread at start-up and the atomic write of one key. It also depends on plan-config-reload.md for changes that arrive while the app runs. The smoke tests use `--theme` to take screenshots in light and dark.

## Issues

## Steps

### Prerequisites

1. Confirm plan-config-and-state.md and plan-config-reload.md are implemented in `~/projects/photosphere/ziggy`: `packages/ziggy/core/src/lib` has the config file reader and the one-key atomic writer the main thread calls and the main thread has the point where a reloaded config file arrives. Every later step that reads, writes or reloads the config file uses those functions by the names those plans gave them. Implement those two plans first when they are not.

### Ziggy repository (`~/projects/photosphere/ziggy`)

2. Add the theme logic, `packages/ziggy/core/src/lib/theme.zig`, with its tests in `packages/ziggy/core/src/test/theme.test.zig` (imported at the bottom of `theme.zig` and referenced from the core's `index.zig` test block the way `remote-control-arguments.zig` is).
    - `Setting = enum { light, dark, system }` and `Theme = enum { light, dark }`.
    - `parseSetting(text) !Setting`: fails with `UnknownTheme` for any other text.
    - `resolve(setting, system: Theme) Theme`: `system` gives the system theme, the others themselves.
    - `takeArgument(allocator, arguments) !TakenTheme`: takes `--theme <value>` out of the argument list (which has no program name), returning the setting or null and the remaining arguments. `--theme` as the last argument fails with `ThemeValueMissing`, a second one with `ThemeGivenTwice` and an unknown value with `UnknownTheme`. Assert the remaining count is the input count less two when the option was present.
    - `Backgrounds = struct { light: u24 = 0xffffff, dark: u24 = 0x000000 }`, with a comment saying the app declares them so the window's colour matches the page's own before the page draws.
    - `ThemeState = struct { setting: Setting, override: bool, system: Theme }`, with `theme()` and the functions the main thread calls: `applySetting`, `applySystem` and `applyConfig` (ignored while `override` is true). Each returns whether the setting or the theme changed, so the main thread sends the event and the native call only on a change.
    - `stateJson(arena, state) ![]u8` gives `{"setting":"system","theme":"dark"}`; `scriptText(arena, state) ![]u8` gives `window.__ziggyTheme = {...};` from it; `nativeJson(arena, state, backgrounds) ![]u8` gives `{"theme","background":"#rrggbb","script"}`.
    - Unit tests cover every function, the three argument errors, the override ignoring a config change and a value written as `#000000` with leading zeros. Use `std.testing.allocator` and a `checkAllAllocationFailures` test for `takeArgument` and `nativeJson`.
    - `mise exec -C ~/projects/photosphere/ziggy -- zig build test` passes.

3. Give the core the theme at start-up.
    - `packages/ziggy/core/src/lib/types.zig` `ZiggyConfig` and `packages/ziggy/core/src/lib/ziggy.h` `ziggy_config` (same order, after `args`): add `system_theme: i32`, with the C enum `ZIGGY_THEME_LIGHT = 0`, `ZIGGY_THEME_DARK = 1` in `ziggy.h` and a matching Zig enum in `types.zig`.
    - `packages/ziggy/core/src/lib/app.zig`: add the optional field `backgrounds` (`theme.Backgrounds`) to `RegisteredApp`, `app_fields`, the field list in the unknown-field compile error and the `App` comment, defaulting to `.{}`.
    - `packages/ziggy/core/src/lib/core.zig` `mainThread` (line 934): before `on_create` (line 1052), take `--theme` out of `start_data.arguments` with `theme.takeArgument`; an error fails the start through `reportStartFailure` with the error's name, which `ziggy_create` prints. Read `theme` from the config file with plan-config-and-state.md's reader; an unknown value is logged with `services.log` as an error naming the value and leaves `system`. Build the `ThemeState` (setting from `--theme` with `override = true`, else from the config file, else `system`; `system` from `config.system_theme`) and pass the remaining arguments to `on_create`.
    - Add a `theme` request beside `ui-query` (line 1128): `pub fn theme(allocator, queue) ![:0]u8` written like `uiQuery` (line 801), posting `{"type":"theme"}` and returning the reply's text, which the main thread answers with `theme.nativeJson`.
    - `packages/ziggy/core/src/lib/ziggy-api.zig`: export `ziggy_theme(handle, size_t *length)` written like `uiQuery` (line 286), keeping its text until the next call. Declare it in `ziggy.h` after `ziggy_ui_query` (line 236) with a comment: the native app calls it after `ziggy_create` and before it loads the frontend and the JSON's fields.
    - Tests in a new `packages/ziggy/core/src/test/theme-start.test.zig`, built like `ui-query.test.zig`: no argument and no config gives `system` and the system theme; `--theme dark` gives `dark` and is missing from the arguments `on_create` receives; a bad `--theme` fails the start; a config `theme = "light"` gives `light`; an unknown config value gives `system` and an error line; `.backgrounds` reaches `ziggy_theme`'s JSON.

4. Add the theme's system messages, event and native call.
    - New `packages/ziggy/core/src/lib/system-messages/theme.zig`, exported from `system-messages.zig` with `get-theme`, `set-theme` and `system-theme` added to `names`:
        - `get-theme`: responds with `stateJson`.
        - `set-theme`: data is `"light"`, `"dark"` or `"system"`, else `InvalidMessageData`. Writes `theme` to the config file with plan-config-and-state.md's one-key atomic write, then `applySetting` (which clears `override`).
        - `system-theme`: data is `"light"` or `"dark"`; `applySystem`.
    - `core.zig` `runSystem` (line 1381): dispatch the three names, giving them only the `ThemeState`, the backgrounds and what they need to send.
    - On every change, send the frontend the system event `{"kind":"system","name":"theme-changed","data":{setting,theme}}` and the native app the call `.theme` with `nativeJson`.
    - `packages/ziggy/core/src/lib/native-message.zig`: add `theme: ThemeCall` (fields `theme`, `background`, `script`) to `Call`, the wire fields, `encode`, `parse` and `typeName`. Document it in `ziggy.h`'s list of calls (line 75 onward): no result.
    - At the point plan-config-reload.md delivers a reloaded config file to the main thread, read `theme` again and call `applyConfig`.
    - `packages/ziggy/core/src/lib/fake-native-app.zig`: record theme calls so tests can expect them.
    - Tests in `packages/ziggy/core/src/test/dispatcher.test.zig`: each message's response and error; `set-theme` writes the config file and sends the event and the call; `system-theme` with setting `system` sends both; with setting `light` it sends neither; a reload with a new `theme` sends both; under `--theme` it sends neither; a reload with the same value sends neither.

5. Give `window.ziggy` the theme.
    - `packages/ziggy/core/src/lib/ziggy-inject.js`: read `window.__ziggyTheme` when the script runs (throw an error naming it when it is missing, because every native app and the dev host inject it first), keep it in a variable, update it on the `theme-changed` system event before calling the listeners. Add `getTheme()` (returns a copy), `setTheme(setting)` (`invokeSystem("set-theme", setting)`), `onThemeChanged` and `removeThemeChangedListener` (`systemEvent("theme-changed")`). Update the comment at the top.
    - `packages/ziggy/frontend/src/ziggy-bridge.ts`: add `ThemeSetting = "light" | "dark" | "system"`, `Theme = "light" | "dark"`, `IThemeState { setting; theme }` and the four methods on `IZiggyBridge`, each commented.
    - `packages/ziggy/frontend/src/test/ziggy-inject.test.ts`: `getTheme` returns the injected state; a `theme-changed` event updates it and calls listeners; a removed listener is not called; `setTheme` posts `set-theme`; a missing `window.__ziggyTheme` throws.
    - `mise exec -C ~/projects/photosphere/ziggy -- bun run compile` and `bun run test` pass.

6. Linux native app (`packages/ziggy/native/linux/src/lib`).
    - `gtk.zig`: declare, each checked against GLib, GIO, GTK 3 and WebKitGTK 4.1's header documentation: `g_dbus_proxy_new_for_bus_sync`, `g_dbus_proxy_call_sync`, `g_variant_new`, `g_variant_get_child_value`, `g_variant_get_variant`, `g_variant_get_uint32`, `g_variant_get_string`, `g_variant_unref`, `g_error_free`, `gtk_settings_get_default`, `g_object_set`, `webkit_web_view_set_background_color`, `webkit_user_content_manager_remove_all_scripts` and the `GdkRGBA` type.
    - New `system-theme.zig`: `fromColorScheme(value: u32) Theme` (1 is dark, anything else light) with `src/test/system-theme.test.zig` and an entry in `src/tests.zig`; `read()` calls the portal's `org.freedesktop.portal.Settings.ReadOne` for `org.freedesktop.appearance` `color-scheme` on the session bus (the same call `gdbus call --session --dest org.freedesktop.portal.Desktop --object-path /org/freedesktop/portal/desktop --method org.freedesktop.portal.Settings.ReadOne org.freedesktop.appearance color-scheme` makes, which returned `(<uint32 1>,)` on this machine); a failure logs one line naming the GLib error and gives light. `watch(native_app)` connects the proxy's `g-signal` and, for `SettingChanged` of that namespace and key, posts `{"kind":"system","name":"system-theme","data":"<theme>"}` with `ziggy_send_message`.
    - `native-app.zig` `start` (line 199): read the system theme before `ziggy_create` and set `config.system_theme`; after `ziggy_create`, call `ziggy_theme` and pass its JSON to a new `applyTheme(native_app, json)`, which sets the web view background, sets `gtk-application-prefer-dark-theme` and puts the user scripts back in order (`webkit_user_content_manager_remove_all_scripts`, then the theme script, then the inject script, lines 253-257). Call `applyTheme` for each `theme` call taken from the core. Start the watch after the core exists.
    - `mise exec -C ~/projects/photosphere/ziggy -- zig build ziggy-test-app-linux` builds and `zig build test` passes.

7. Windows native app (`packages/ziggy/native/windows/src/lib`).
    - New `system-theme.zig`: `fromAppsUseLightTheme(value: ?u32) Theme` (0 is dark, missing or anything else light) with `src/test/system-theme.test.zig`; `read()` reads `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize` `AppsUseLightTheme` with `RegGetValueW` (`advapi32` is already linked).
    - `native-app.zig`: move `ShowWindow` and `UpdateWindow` (lines 573-576) to the end of `onControllerCreated` (line 881), after the theme is applied. Set `config.system_theme` before `ziggy_create`. A new `applyTheme` sets `DwmSetWindowAttribute(window, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, ...)` (link `dwmapi` in Ziggy's `build.zig` Windows list near line 800 and include `dwmapi.h` in `src/c.h`), `ICoreWebView2Controller2.put_DefaultBackgroundColor` (through `QueryInterface`) and a background brush the window procedure (line 612) paints `WM_ERASEBKGND` with. It adds the theme script with `AddScriptToExecuteOnDocumentCreated` before the inject script (line 957), keeps the id the completion handler gives (`scriptAddedInvoke`, line 2027) and on a change removes it with `RemoveScriptToExecuteOnDocumentCreated` and adds the new one. Navigate only once both scripts are added. `windowProc` handles `WM_SETTINGCHANGE` whose `lParam` is the string `ImmersiveColorSet` by reading the theme again and posting `system-theme`.
    - `mise exec -C ~/projects/photosphere/ziggy -- zig build ziggy-test-app-windows-check` builds and `zig build test` passes.

8. macOS and iOS native apps.
    - `packages/ziggy/native/macos/Sources/ZiggyNativeMacOS/ZiggyBridge.swift`: a static `systemTheme()` reading `UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"`; set `config.system_theme` in `start` (line 199); observe `AppleInterfaceThemeChangedNotification` on `DistributedNotificationCenter.default()` and post `system-theme`. `applyTheme` sets `NSApp.appearance` (`.aqua` or `.darkAqua`), the window's `backgroundColor`, `webView.underPageBackgroundColor` behind `#available(macOS 12.0, *)`. It replaces the user scripts (`removeAllUserScripts`, then the theme script, then the inject script, lines 126-155). Handle the `theme` call in `doCall` (line 327).
    - `packages/ziggy/native/ios/Sources/ZiggyNativeIOS/ZiggyBridge.swift`: pass `CommandLine.arguments` after the program's name, without `--remote-control` and its address, as `config.args` in `start` (line 177), as the macOS bridge does (line 239). `systemTheme()` reads `UIScreen.main.traitCollection.userInterfaceStyle`; set `config.system_theme`; observe `UIApplication.didBecomeActiveNotification` and post `system-theme`. `applyTheme` sets `webView.window?.overrideUserInterfaceStyle`, `webView.isOpaque = false`, `webView.backgroundColor` and `webView.scrollView.backgroundColor`. It replaces the user scripts (lines 127-155). Handle the `theme` call in `doCall` (line 305).

9. Android native app.
    - `packages/ziggy/native/android/src/main/java/dev/ziggy/nativeapp/ThemeExtra.java`: the extra `ziggy.theme`, written like `RemoteControlExtra.java`, with `ThemeExtraTest.java` beside `RemoteControlExtraTest.java`.
    - `ZiggyNative.java` `create` (line 12) and `packages/ziggy/core/src/lib/jni.zig` (`CreateArguments` line 266, `createBridge` line 273, the export near line 538): add `String theme` and `int systemTheme`. When the theme is given, `createBridge` passes `--theme` and the value as `config.args` with `arg_count` 2 (line 357), so the core takes it the same way as on the desktop.
    - `ZiggyNativeApp.java` `start` (line 150): read the extra and the system theme (`(activity.getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES`) and pass them; after `create`, read `uiTheme(handle)` (a new JNI function calling `core.theme`) and apply it before `loadUrl`. `applyTheme` sets `webView.setBackgroundColor` and the window's decor view background and adds the theme script with `WebViewCompat.addDocumentStartJavaScript` before the inject script (line 271), keeping the `ScriptHandler` and calling `remove()` on a change. Add `public void onConfigurationChanged(Configuration configuration)`, which posts `system-theme` when the night bit changed. Handle the `theme` call where the other calls are taken.
    - `apps/ziggy-template/native/android/app/src/main/java/dev/ziggy/template/MainActivity.java` and `apps/ziggy-test-app/native/android/app/src/main/java/dev/ziggy/testapp/MainActivity.java`: override `onConfigurationChanged` to call `super` and then `nativeApp.onConfigurationChanged`. The manifests already list `uiMode` in `configChanges`.
    - `mise exec -C ~/projects/photosphere/ziggy -- bun run test:android-shell` passes and `bun run build:ziggy-template:android` builds.

10. Dev mode.
    - `packages/ziggy/dev/src/lib/dev-host.zig`: serve `/__ziggy/theme.js` (beside `/__ziggy/inject.js`, line 754) with the `script` of `ziggy_theme`'s JSON, fetched through the main thread as `sendDevShortcuts` does (line 813); take the `theme` call and do nothing with it, with a comment saying the browser has no window chrome and its next load fetches the new script.
    - `packages/ziggy/dev/src/lib/proxy.zig` `dev_scripts` (line 13): add `<script src="/__ziggy/theme.js"></script>` before the inject script.
    - `packages/ziggy/dev/src/lib/dev-client.js`: post `system-theme` with the browser's `prefers-color-scheme` once the socket opens and on each change of that media query. `packages/ziggy/frontend/src/test/dev-client.test.ts` covers both.

11. Template and test app frontends.
    - `apps/ziggy-template/frontend/index.html`: replace `:root { color-scheme: light dark; }` with `html { background: #ffffff; } html[data-theme="dark"] { background: #000000; }` and add an inline script in `<head>` that sets `document.documentElement.dataset.theme` and `style.colorScheme` from `window.ziggy.getTheme().theme`. `apps/ziggy-template/frontend/src/main.ts`: on `onThemeChanged`, set both again. The template's `app.zig` sets no `.backgrounds`, because the defaults are its colours.
    - `apps/ziggy-test-app/frontend/index.html` and `src/main.ts`: the same, plus an element `data-id="first-theme"` holding the theme the inline script read, `data-id="theme"` holding `setting theme` and updated on every event and buttons `data-id="set-theme-light"`, `set-theme-dark` and `set-theme-system` calling `setTheme`.

12. Smoke tests.
    - `smoke-tests/lib/linux.sh`, `windows.sh`, `macos.sh`, `ios.sh`, `ios-device.sh` and `android.sh` and the same files under `apps/ziggy-template/smoke-tests/lib`: when `ZIGGY_THEME` is set, start the app with `--theme "$ZIGGY_THEME"` (`--es ziggy.theme "$ZIGGY_THEME"` on Android). Document the variable in the interface comment of `smoke-tests/lib/common.sh` and in `smoke-tests/run.md`.
    - New `smoke-tests/28-theme/test.sh`: with `ZIGGY_THEME=dark`, `first-theme` is `dark` and `theme` is `system dark` or `dark dark` per the config; clicking `set-theme-light` shows `light light`; `restart_test_app` with `ZIGGY_THEME` unset starts on `light light`, read from the config file.
    - New `smoke-tests/desktop-only/29-theme-screenshots/test.sh`: start with `ZIGGY_THEME=light`, take a `screenshot` into the test directory, restart with `ZIGGY_THEME=dark`, take another, check both files are non-empty and that `cmp -s` finds them different.
    - `mise exec -C ~/projects/photosphere/ziggy -- bun run test:smoke` passes, then `bun run test:smoke:android` and `bun run --filter=ziggy-template test:smoke`.

13. Ziggy documentation.
    - New `docs/user-guide/theme.md`: the setting and its values, the config key, `--theme` and the `ziggy.theme` extra, what follows the system on each platform, `getTheme`, `setTheme`, `onThemeChanged`, `.backgrounds`, how a page avoids a flash (read `getTheme()` in an inline script in `<head>`) and how smoke tests take light and dark screenshots with `--theme`. Link it from `docs/user-guide.md` after "Menus".
    - `docs/development/architecture.md`: add `get-theme`, `set-theme` and `system-theme` to the system message table (line 97 onward) and `theme-changed` to the event table (line 114 onward), the `theme` call to the native call text and `ziggy_theme` to "The message bridge".
    - `docs/user-guide/testing.md`: `--theme` and `ZIGGY_THEME`. `docs/user-guide/app-declaration.md`: `.backgrounds`. `docs/development/dev-mode.md`: `/__ziggy/theme.js` and the browser's theme.
    - `docs/upgrade-notes.md`: under `## v0.0.24`, add lines for `MainActivity.onConfigurationChanged`, the four new `IZiggyBridge` methods a fake must add, the optional `.backgrounds`, `--theme` being taken before `on_create` and the template's `index.html` theme script.

### Example repositories (`ziggy-example-vite`, `ziggy-example-rsbuild`)

14. No change: both take Ziggy from a version tag and Ziggy's `CLAUDE.md` moves them to a new release once it exists, carrying the upgrade notes from step 13.

### Photosphere repository (`~/projects/photosphere/photosphere`)

15. Take the local Ziggy.
    - `build.zig.zon`: replace the `ziggy` dependency's `.url` and `.hash` with `.path = "../ziggy"`.
    - `apps/photosphere-frontend/package.json` line 17: `"ziggy": "file:../../../ziggy"`; run `mise exec -C ~/projects/photosphere/photosphere -- bun install` and check `apps/photosphere-frontend/node_modules/ziggy/packages/ziggy/frontend/src/ziggy-bridge.ts` holds `getTheme`.
    - `apps/photosphere/native/android/settings.gradle`: replace the `sourceControl` block with `includeBuild('../../../../../ziggy/packages/ziggy/native/android') { name = 'ziggy-native-android' }`, as Ziggy's template does.
    - `mise exec -C ~/projects/photosphere/photosphere -- zig build` passes.

16. Remove Photosphere's own theme from the backend.
    - `apps/photosphere/core/src/app.zig`: add `.backgrounds = .{ .light = 0xffffff, .dark = 0x000000 }`, with a comment that these are Joy's default `background.body`.
    - `packages-zig/photosphere-core/src/lib/page-query.zig`: drop `theme` from `pageQuery` and `buildQuery` and the file's comment; update `src/test/page-query.test.zig` (the tests at lines 39-91 assert the query without `&theme=` and the "saved theme" test at line 71 goes).
    - `packages-zig/photosphere-core/src/lib/config-and-state.zig` lines 176-195: remove the `theme` branch and its comment lines. `src/test/config-and-state.test.zig`: remove the theme tests at lines 144-160 and 288-296 and the theme reads at lines 132 and 320.
    - `packages-zig/photosphere-core/src/lib/events.zig`: remove `sendThemeChanged` (line 111) and `theme-changed` from the top comment; `src/test/events.test.zig`: remove the theme tests at lines 83-94 and 168-179.
    - `packages-zig/node-api-zig/src/lib/app-config.zig` (`getTheme`, `SetThemeMutator`, `setTheme`, lines 89-120), `config-format.zig` (`IConfigTheme`, the `theme` field, `ALLOWED_THEMES`, its read at line 294 and write at line 384), `app-config-format.zig` (lines 7-8 and 37-39) and the comment in `state-format.zig` line 9, as they stand after plan-config-and-state.md; and their tests in `src/test/config-format.test.zig`, `app-config-format.test.zig`, `app-config.test.zig` and `config-file.test.zig`.
    - `packages-zig/photosphere-core/src/lib/menu.zig`: the comment at line 13 says the theme items set Ziggy's theme.
    - `mise exec -C ~/projects/photosphere/photosphere -- bun run test:zig` passes.

17. Move the frontend onto Ziggy's theme.
    - `apps/photosphere-frontend/index.html` lines 7-17: the inline script reads `window.ziggy.getTheme().theme` and sets `data-joy-color-scheme` and `style.colorScheme`; add `<style>html { background: #FFF; } html[data-joy-color-scheme="dark"] { background: #000; }</style>`.
    - `apps/photosphere-frontend/src/app.tsx` lines 51-53: `initialTheme` is `ziggy.getTheme().theme`; pass it to `<StoriesPage initialTheme={...} />` as well as `<Main>`.
    - `packages/user-interface/src/context/platform-context.tsx` line 331: replace `onThemeChanged` with `getTheme(): IThemeState`, `setTheme(setting): Promise<void>` and `onThemeChanged(callback: (state: IThemeState) => void): Unsubscribe`, with `IThemeState` (`setting`, `theme`) defined in that file.
    - `apps/photosphere-frontend/src/lib/platform-provider-ziggy.tsx`: remove `themeCallbacksRef` (line 126) and the `theme-changed` listener (lines 359-374); implement the three with `ziggy.getTheme`, `ziggy.setTheme` and `ziggy.onThemeChanged`/`removeThemeChangedListener`; the `set-theme` effect (line 528) calls `ziggy.setTheme(effect.theme)`; update the context value (line 934). `packages/user-interface/src/stories/mocks/index.tsx` line 178 and `apps/photosphere-frontend/src/test/fake-ziggy.ts` gain the new members.
    - `packages/user-interface/src/main.tsx`: `IMainProps.initialTheme` is `'light' | 'dark'`; the listener (lines 191-199) calls `setMode(state.theme)` and logs `The theme is ${state.theme} (setting ${state.setting}).` with `log.info`.
    - New hook `packages/user-interface/src/lib/use-theme-setting.ts`: holds `platform.getTheme().setting` and follows `onThemeChanged`. `components/theme-toggle.tsx` (lines 45-58), `pages/configuration.tsx` (lines 24-35 and `value={mode}` at line 58) and `components/configuration-dialog.tsx` (lines 60-70) show the hook's setting and call `platform.setTheme`, no longer `setMode` and `config.set("theme")`.
    - `packages/user-interface/src/stories/stories-page.tsx`: take `initialTheme` as a prop instead of `resolveInitialTheme(themeOverrideFromEnv(), "system")` (line 33) and remove the import at line 9; the comment at lines 366-372 says every story is shown in light and then dark.
    - `packages/user-interface/src/index.tsx` line 5: remove the `env-theme` export. `apps/photosphere-frontend/vite.config.ts` lines 35-36: remove `__PHOTOSPHERE_THEME__`.
    - `mise exec -C ~/projects/photosphere/photosphere -- bun run compile` and `bun run test` pass.

18. Photosphere smoke tests.
    - `apps/photosphere-smoke-tests/lib/linux.sh` (line 76), `windows.sh`, `macos.sh`, `ios.sh` (line 214), `ios-device.sh` and `android.sh` (line 387): when `PHOTOSPHERE_SMOKE_THEME` is set, pass `--theme "$PHOTOSPHERE_SMOKE_THEME"` (`--es ziggy.theme` on Android). Document it in `lib/common.md` and `run.md`.
    - `apps/photosphere/native/android/app/src/main/java/au/com/codecapers/photosphere/ziggy/MainActivity.java`: forward `onConfigurationChanged` as in step 9.
    - New `apps/photosphere-smoke-tests/67-theme/test.sh`: start with `PHOTOSPHERE_SMOKE_THEME=dark`, `wait_for_log` `The theme is dark`, take a screenshot; click `theme-toggle-button` then `theme-option-light`, `wait_for_log` `The theme is light (setting light).`, take a screenshot, check both PNGs are non-empty and `cmp -s` finds them different and `read_config_file` of Ziggy's config file holds `theme = "light"`; restart without the variable and `wait_for_log` `The theme is light`. `check_no_errors` at the end.
    - `PHOTOSPHERE_SMOKE_SCENARIO=67-theme mise exec -C ~/projects/photosphere/photosphere -- bun run test:ziggy` passes, then `PHOTOSPHERE_SMOKE_SCENARIO=67-theme bun run test:ziggy:and`, then `bun run tev`.

19. Photosphere documentation.
    - `docs/theme-override.md`: rewrite as "Forcing a theme with --theme": `--theme light|dark|system` on the app's command line (the `ziggy.theme` extra on Android), never saved and `PHOTOSPHERE_SMOKE_THEME` for the smoke tests.
    - `packages/user-interface/src/stories/README.md` lines 25 and 31: the stories cycle shows every story in light and then dark and the initial theme is Ziggy's.
    - `docs/photosphere-on-ziggy.md` line 33: the query is `restApiUrl` and `testMode=1`; add a sentence that the theme is Ziggy's and the page reads it with `window.ziggy.getTheme()`.

### Clean up

20. Delete the files whose subject no longer exists: `packages/user-interface/src/lib/env-theme.ts` and `packages/user-interface/src/test/lib/env-theme.test.ts` in Photosphere. Then run `mise exec -C ~/projects/photosphere/photosphere -- bun run compile` and `bun run test` again.

## Unit Tests

- `theme.test.zig`: `parseSetting`, `resolve`, `takeArgument` (present, absent, missing value, given twice, unknown value, allocation failures), `ThemeState.applySetting`/`applySystem`/`applyConfig` (changed and unchanged, override), `stateJson`, `scriptText`, `nativeJson` (colour formatting, allocation failures).
- `theme-start.test.zig`: start-up from argument, config file, nothing and a bad config value; arguments given to `on_create`; `ziggy_theme`'s JSON with `.backgrounds`.
- `dispatcher.test.zig`: `get-theme`, `set-theme` (valid, invalid, config write, event, call), `system-theme`, reload with and without override.
- `native-message` tests: the `theme` call encodes and parses.
- `app.test.zig`: `.backgrounds` accepted and defaulted.
- Linux `system-theme.test.zig` (`fromColorScheme`) and Windows `system-theme.test.zig` (`fromAppsUseLightTheme`).
- `ThemeExtraTest.java`.
- `ziggy-inject.test.ts` and `dev-client.test.ts` as in steps 5 and 10.
- Photosphere: updated `page-query.test.zig`, `config-and-state.test.zig`, `events.test.zig` and the node-api-zig config tests; `menu-actions.test.ts` still passes unchanged.

## Smoke Tests

- Ziggy `smoke-tests/28-theme`: the theme from `--theme`, read before the first script; `setTheme`; the setting kept across a restart. Linux and Android here.
- Ziggy `smoke-tests/desktop-only/29-theme-screenshots`: light and dark screenshots differ. Linux here.
- Every existing scenario in Ziggy, the template and Photosphere passes, which covers the inject script reading `__ziggyTheme` on every load.
- Photosphere `67-theme`: `--theme`, the theme toggle (the React components and hooks changed in step 17), the config write and the restart. Linux and Android here.

## Verify

- In Ziggy: `zig build`, `zig build test`, `bun run compile`, `bun run test`, `bun run test:android-shell`, `bun run test:smoke`, `bun run test:smoke:android` and `bun run --filter=ziggy-template test:smoke` exit 0, each through `mise exec -C ~/projects/photosphere/ziggy --`.
- `zig build ziggy-test-app-windows-check` exits 0.
- In Photosphere: `bun run tev` exits 0 through `mise exec -C ~/projects/photosphere/photosphere --`.
- `bash -n` passes over every edited shell script.
- `grep -rn "PHOTOSPHERE_THEME\|themeOverrideFromEnv\|resolveInitialTheme\|sendThemeChanged\|IConfigTheme" ~/projects/photosphere/photosphere --exclude-dir=node_modules --exclude-dir=.zig-cache --exclude-dir=zig-out --exclude-dir=plans --exclude-dir=desktop --exclude-dir=smoke-tests` prints nothing.
- CI-only: the macOS and iOS native apps, the Windows smoke tests and `bun run test:smoke:ios`.

## Notes

- Checked against the code: Ziggy has no theme code today (`grep -rni theme` finds only Mermaid diagram settings, the Android manifest theme and `color-scheme: light dark` in the template and test app pages). plan-remote-control.md is implemented (`remote-control.zig`, `remote-control-arguments.zig`, `tools/remote-control-server`), so this plan builds on `--remote-control` as it is.
- The portal call was run on this machine and returned dark (`uint32 1`) for both `ReadOne` and `Read` and its `SettingChanged(s namespace, s key, v value)` signal is listed by `gdbus introspect`.
- The page gets the theme from Ziggy's own script and not from `prefers-color-scheme`, because the web views do not follow an app's own setting in the same way on every platform and the app may choose light while the OS is dark.
- The theme script is replaced on every change so a reload after a change also starts in the right theme.
- `ziggy_theme` blocks the UI thread on the main thread, as `ziggy_ui_query` does; the main thread never waits on the UI thread while answering it.
- Photosphere's Joy `CssVarsProvider` is given only `light` or `dark`, so `system` is resolved once, by Ziggy.
- A window started by plan-new-window.md reads the theme from the config file; it gets `--theme` only when that plan passes the parent's arguments.
- The config reload that carries a theme change between windows is plan-config-reload.md's; this plan only reacts to it.
- Moving Photosphere's dependencies back from the local paths to a Ziggy version tag happens when Ziggy is next released, outside this plan.
