# External links open in the system web browser

## Decisions not approved by a human

- The fix is to let the frontend's script open windows without a user gesture on Linux, macOS, iOS and Android, so every `window.open` and `target="_blank"` reaches the navigation handlers Ziggy already has.
- No new `window.ziggy` call, system message or native call is added for opening a link.
- The native handlers that already decide every navigation (`ziggy_check_url`) stay as they are and stay the only place an address is judged.
- The Linux native app reports a link the system could not open on standard error and carries on, as macOS and iOS already do.
- The Windows native app reports a link ShellExecute could not open and carries on, instead of ending the app.
- The proof that a link reached the system comes from outside the app, with no new test hook: a URL handler of the test's own on Linux and the device log on Android.
- On Windows, macOS and iOS the smoke scenario proves only that the frontend stayed loaded (see Open questions).
- Ziggy's new smoke scenario is `smoke-tests/28-external-links`, run on every platform, against three new elements of the test app.
- The Ziggy template and its smoke tests are not changed.
- The example repositories get no change from this plan: they receive it when they move to the Ziggy release that holds it.
- Photosphere has no code of its own for external links, so it keeps using `window.open` and `target="_blank"` unchanged.
- Photosphere gets a smoke scenario, `67-external-links`, for an About page link and the Help menu item.
- Photosphere's `sync-linux.sh` gets a `--ziggy-fork <path>` option so the Linux build can take a local Ziggy checkout.
- Photosphere's step is checked here on Linux against the local Ziggy only, and lands with Photosphere's move to the Ziggy release that holds the Ziggy steps.
- The About page's website link gets the data-id `about-website-link`.
- The documentation goes in Ziggy's `docs/development/architecture.md` and `docs/user-guide/testing.md`, and Photosphere's `docs/photosphere-on-ziggy.md`.
- No Ziggy upgrade note is written, because no app changes its code for this.

## Open questions

1. **How do the smoke tests prove on Windows, macOS and iOS that a link was handed to the system?** On those platforms the system's handler for `https` cannot be replaced by a test without changing a machine-wide setting: Windows keeps the default browser under a hash-protected `UserChoice` registry key, and macOS asks the user to confirm a new default browser. The iOS simulator opens Mobile Safari, which a test might see with `xcrun simctl`, but that cannot be checked from this Linux machine. ANY NEW TEST HOOK MUST BE APPROVED BY THE HUMAN FIRST (Ziggy `CLAUDE.md`).
    - Option A (recommended): no hook. On Windows, macOS and iOS the scenario proves only that the frontend stayed loaded, and the handoff is proven on Linux and Android, where the system's handler is the same function call. The real browser opens on those runners during the scenario.
    - Option B: a hook. When the app is started with `--remote-control`, each native app sends the address to the remote control connection instead of opening it, and a new `opened-urls` command returns them. Every platform proves the same thing and no browser opens on a runner, but the call to the system's opener is never run under test.
    - Option C: Option A, plus an iOS simulator check with `xcrun simctl` that Mobile Safari started, written and run on a Mac as a CI-only check.
2. **Is the Android device log the right evidence on Android?** No device was attached while this plan was written, so the log line could not be read. Step 4 matches the `START` line that `ActivityTaskManager` logs for the `VIEW` intent, after checking that the device has an activity for `https`.
    - Option A (recommended): match the `ActivityTaskManager` `START` line with `act=android.intent.action.VIEW` and the link's host, read with `logcat -d -T <time the scenario started>`.
    - Option B: read the resumed activity from `dumpsys activity activities` after each click and match the browser's package and the link's host.

## Overview

A link to an outside page must open in the system web browser, not inside the app's web view, on Linux, Windows, macOS, Android and iOS: a plain link, a link with `target="_blank"` and a call to `window.open`. Ziggy already decides every navigation with the core's origin check (`origin-check.zig`, through `ziggy_check_url`), and each native app opens an external address with the platform's opener: `gtk_show_uri_on_window` on Linux (`onDecidePolicy`), `ShellExecuteW` on Windows (`navigationInvoke`, `newWindowInvoke`), `NSWorkspace.shared.open` on macOS and `UIApplication.shared.open` on iOS (`decidePolicyFor`, `createWebViewWith`) and an `ACTION_VIEW` intent on Android (`shouldOverrideUrlLoading`, with `setSupportMultipleWindows(false)` so a new window loads as a navigation). What fails today is any `window.open` or `target="_blank"` that is not run inside a user's click: WebKitGTK's `javascript-can-open-windows-automatically` defaults to false (read from the installed `WebKit-6.0.gir`), WKWebView's `javaScriptCanOpenWindowsAutomatically` defaults to false on iOS and Android's `setJavaScriptCanOpenWindowsAutomatically` defaults to false, and Ziggy sets none of them, so the web view's popup blocker drops the request before any handler of Ziggy's sees it. Photosphere's Help menu item does exactly that: the menu event reaches the frontend with no user gesture and calls `window.open` (`apps/photosphere-frontend/src/lib/platform-provider-ziggy.tsx` line 538). The bug report button calls `window.open` after an `await` (`packages/user-interface/src/lib/bug-report.ts` line 65). This plan turns those settings on, since the handlers never create a window, makes a failed open noisy on Linux and survivable on Windows, and adds smoke scenarios to Ziggy and Photosphere that click each kind of link and prove the frontend stayed loaded and, where it can be seen from outside the app, that the system was asked to open the address.

## Issues

## Steps

### Ziggy repository (`../ziggy` from Photosphere)

1. Check the pre-commit hook is installed, as Ziggy's `CLAUDE.md` requires: `$(git -C ../ziggy rev-parse --git-common-dir)/hooks/pre-commit` links to `.githooks/pre-commit`; when it does not, run `mise exec -C ../ziggy -- bun run install-hooks`.

2. Add the external links to the test app's frontend.
    - `apps/ziggy-test-app/frontend/index.html`: add a `<section>` with the heading "External links" holding:
        - an input `data-id="external-link-marker"`, which the scenario types a marker into; a reload or a navigation away and back would clear it;
        - `<a data-id="link-plain" href="https://plain.example.com/ziggy-external-link">A plain link</a>`;
        - `<a data-id="link-new-window" target="_blank" href="https://new-window.example.com/ziggy-external-link">A link to a new window</a>`;
        - `<button data-id="open-window">Open a window</button>`.
    - `apps/ziggy-test-app/frontend/src/main.ts`: a function `startExternalLinks()`, called beside `startTasks()` and the other start functions, that adds a click listener to `open-window` calling `window.open("https://window-open.example.com/ziggy-external-link", "_blank")`. Its comment says why: the test app's `click` command runs with no user gesture, which is the case the popup blocker drops.
    - Each address has its own host so the device log on Android, which shows only the scheme and host of an intent's address, names which element sent it.
    - `bun run compile` and `bun run test` pass.

3. Let the frontend open windows without a user gesture, and make a failed open noisy.
    - Linux, `packages/ziggy/native/linux/src/lib/gtk.zig`: declare `webkit_settings_set_javascript_can_open_windows_automatically(settings: *WebKitSettings, enabled: gboolean) void` beside `webkit_settings_set_enable_developer_extras` (line 157).
    - Linux, `packages/ziggy/native/linux/src/lib/native-app.zig`: after line 242 call it with `1` on `c.webkit_web_view_get_settings(web_view)`, with a comment saying why: the popup blocker drops a `window.open` or a `target="_blank"` that no click of the user's ran, and `onDecidePolicy` decides every new window and never creates one. In `onDecidePolicy` (line 330) pass a `?*c.GError` to `gtk_show_uri_on_window` (line 346) and, when it returns 0, print `ziggy native app: could not open <uri> in the system browser: <message>` with `std.debug.print`, read through `c.GErrorFields` as `takeScreenshot`'s callback does near line 1013, and free the error with `c.g_error_free`.
    - Windows, `packages/ziggy/native/windows/src/lib/native-app.zig`: `openExternally` (line 850) prints `ziggy native app: could not open an external link, ShellExecute returned <n>` with `std.debug.print` and returns, instead of calling `fatal`. Update its comment. WebView2 raises `NewWindowRequested` for every `window.open` whatever started it, so it needs no setting.
    - macOS, `packages/ziggy/native/macos/Sources/ZiggyNativeMacOS/ZiggyBridge.swift`: after line 158 set `configuration.preferences.javaScriptCanOpenWindowsAutomatically = true`, with the same comment. macOS's default is already true; the setting is passed explicitly so a change of default cannot change Ziggy.
    - iOS, `packages/ziggy/native/ios/Sources/ZiggyNativeIOS/ZiggyBridge.swift`: after `let configuration = WKWebViewConfiguration()` (line 153) set `configuration.preferences.javaScriptCanOpenWindowsAutomatically = true`, with the same comment.
    - Android, `packages/ziggy/native/android/src/main/java/dev/ziggy/nativeapp/ZiggyNativeApp.java`: after `settings.setSupportMultipleWindows(false)` (line 259) call `settings.setJavaScriptCanOpenWindowsAutomatically(true)`, with a comment that, with multiple windows off, a new window loads in this web view as a navigation and `shouldOverrideUrlLoading` decides it.
    - `mise exec -C ../ziggy -- zig build`, `mise exec -C ../ziggy -- zig build test` and `mise exec -C ../ziggy -- bun run test:android-shell` pass.

4. Let the smoke tests see a link reach the system, from outside the app.
    - New `smoke-tests/lib/record-opened-url.sh`, executable, `#!/usr/bin/env bash`, usage printed with no arguments: `record-opened-url.sh <record file> <address>` appends the address as one line to the record file. Add `smoke-tests/lib/record-opened-url.md` beside it covering what it is for (the Linux URL handler of `28-external-links`), how it is invoked and each argument. Run `bash -n` over it.
    - `smoke-tests/lib/linux.sh`:
        - `ziggy_platform_start` (line 38): add `XDG_CONFIG_HOME="$test_dir/config"` to the `env` beside `XDG_DATA_HOME`, so GIO reads the scenario's own `mimeapps.list` and never the user's.
        - New `ziggy_platform_watch_opened_urls <test_dir>`, called before `start_test_app`: writes `$test_dir/data/applications/ziggy-test-browser.desktop` (`[Desktop Entry]`, `Type=Application`, `Name=Ziggy test browser`, `MimeType=x-scheme-handler/http;x-scheme-handler/https;x-scheme-handler/mailto;`, `Exec="<absolute path of record-opened-url.sh>" "$test_dir/opened-urls.txt" %u`) and `$test_dir/config/mimeapps.list` (`[Default Applications]` mapping `x-scheme-handler/http`, `x-scheme-handler/https` and `x-scheme-handler/mailto` to `ziggy-test-browser.desktop`). `gtk_show_uri_on_window` launches the default application for the scheme through GIO, so it runs the recorder.
        - New `ziggy_platform_opened_urls <test_dir>`: prints `$test_dir/opened-urls.txt`, or nothing when it does not exist.
    - `smoke-tests/lib/android.sh`:
        - New `ziggy_platform_watch_opened_urls <test_dir>`: runs `ziggy_adb shell cmd package query-activities -a android.intent.action.VIEW -d https://plain.example.com/` and fails with `The device has no activity that opens https addresses, so an external link has nowhere to go.` when it lists none, then writes the device's time, `ziggy_adb shell date +'%m-%d %H:%M:%S.000'`, to `$test_dir/logcat-since`.
        - New `ziggy_platform_opened_urls <test_dir>`: prints the hosts of the `VIEW` intents started since then, from `ziggy_adb logcat -d -v brief -T "<logcat-since>" -s ActivityTaskManager:I`, taking each line that holds `act=android.intent.action.VIEW` and printing the `dat=` value.
    - Document both functions in the interface comment at the top of `smoke-tests/lib/common.sh`, marked "(Linux and Android)". Add a helper `wait_for_opened_url <host> [seconds]` to `common.sh` that waits until a line of `ziggy_platform_opened_urls "$ZIGGY_TEST_DIR"` (the scenario's directory as `start_test_app` names it) holds the host and fails naming the host and what was printed when it never does.
    - Run `bash -n` over every edited script.

5. Add the scenario `smoke-tests/28-external-links/test.sh`, in the form of `27-actions/test.sh`, with a comment at the top giving its goal and method.
    - When the platform library defines `ziggy_platform_watch_opened_urls` (`declare -F`), call it. Then `start_test_app` and `type_into external-link-marker "still here"`.
    - For each of `link-plain`, `link-new-window` and `open-window`: `click` it; when the platform library defines `ziggy_platform_opened_urls`, `wait_for_opened_url` with that element's host; then `wait_for_value external-link-marker "still here"`, which proves the test app's frontend is still the page in the web view and was not reloaded.
    - Add the scenario to the list in `smoke-tests/run.md`.
    - Run `mise exec -C ../ziggy -- bun run test:smoke -- 28 2>&1 | tee ../ziggy/tmp/smoke-28.log` and it passes.
    - Run `adb devices`. When a serial reads `device`, run `mise exec -C ../ziggy -- bun run test:smoke:android -- 28` and it passes.

### Example repositories (`ziggy-example-vite` and `ziggy-example-rsbuild`)

6. No change. Their native apps are Ziggy's, taken from a Ziggy version tag, and their own code never opens a link; they get this behaviour when they move to the Ziggy release that holds steps 2 to 5.

### Photosphere repository

7. Let the Linux build take a local Ziggy. `apps/photosphere/scripts/sync-linux.sh`: add the option `--ziggy-fork <path>`, which adds `--fork=<path>` to the `zig build photosphere-linux` line; an unknown argument still fails as it does. Document it in `apps/photosphere/scripts/sync-linux.md` (and `build-linux.md`, which passes its arguments through). Run `bash -n` over the script.

8. Add the Photosphere scenario.
    - `packages/user-interface/src/pages/about.tsx` line 163: add `data-id="about-website-link"` to the Photosphere website `Link`.
    - New `apps/photosphere-smoke-tests/lib/record-opened-url.sh` with its `.md`, the same as Ziggy's in step 4 (a script of this repository's own, since Photosphere never runs Ziggy's scripts).
    - `apps/photosphere-smoke-tests/lib/linux.sh`: in the app's `env` (line 61) add `XDG_CONFIG_HOME="$test_dir/home/.config"`, and add `photosphere_platform_watch_opened_urls <test_dir>` and `photosphere_platform_opened_urls <test_dir>`, written as Ziggy's Linux ones are, with the desktop file under `$test_dir/data/applications`.
    - `apps/photosphere-smoke-tests/lib/android.sh`: the same two functions as Ziggy's Android ones, using `photosphere_adb`.
    - Document both in `apps/photosphere-smoke-tests/lib/common.md`, `linux.md` and `android.md`.
    - New `apps/photosphere-smoke-tests/67-external-links/test.sh`, in the form of `61-desktop-menu/test.sh`, with a comment at the top giving its goal and method: watch the opened addresses where the platform library can, `start_app`, `wait_for_ready`, `send_command "$APP_PORT" navigate '{"page":"/about"}'`, `send_command "$APP_PORT" click '{"dataId":"about-website-link"}'`, wait for `photosphere.codecapers.com.au` among the opened addresses where they can be seen, then read `about-version` with `read_value` to prove the About page is still the page shown. On Linux, Windows and macOS also run the Help menu item with `send_command "$APP_PORT" menu '{"action":"help"}'`, wait for `github.com`, and read `about-version` again. End with `check_no_errors`.
    - Build against the local Ziggy and run the scenario: `mise exec -C . -- bun run --filter=ziggy build:linux -- --prefix "$PWD/tmp/external-links-build" --ziggy-fork "$(realpath ../ziggy)"`, then `PHOTOSPHERE_SMOKE_BUILD="$PWD/tmp/external-links-build" mise exec -C . -- bun run test:ziggy -- 67`, which passes. `tmp/` is already in `.gitignore`.
    - `mise exec -C . -- bun run compile` passes.

### Documentation

9. Write the documentation.
    - Ziggy `docs/development/architecture.md`, after "The bundled frontend": a section "Links to other pages" saying that each native app asks the core's origin check about every navigation and every new window; the app's own frontend loads, an `http`, `https` or `mailto` address opens with the platform's opener (named per platform) and anything else is blocked; no new window is ever created; `window.open` and `target="_blank"` work with or without a click of the user's, because each native app lets the frontend open windows without one; an address the system cannot open is written to standard error and the app carries on. Name the smoke scenario `28-external-links`.
    - Ziggy `docs/user-guide/testing.md`: one paragraph saying how `28-external-links` sees an address reach the system on Linux (a URL handler of the scenario's own, through `XDG_CONFIG_HOME` and `XDG_DATA_HOME`) and on Android (the device log), and that elsewhere it checks the frontend stays loaded.
    - Photosphere `docs/photosphere-on-ziggy.md`: one line that the Help menu, the About page's links and every other link to an outside page open in the system browser through Ziggy, with no code of Photosphere's own.
    - Photosphere `apps/photosphere-smoke-tests/run.md`: add `67-external-links` to its list of scenarios.

### Clean up

10. Delete the build directory `tmp/external-links-build` in Photosphere with `find tmp/external-links-build -type f -delete` followed by `find tmp/external-links-build -depth -type d -empty -delete` (no `rm -r`).

## Unit Tests

- No function with logic is added or changed. The changed code sets a web view option or calls the platform's opener and reports its failure, which no unit test can run without the platform's web view; `28-external-links` and `67-external-links` cover it.
- `packages/ziggy/core/src/test/origin-check.test.zig` already covers the decision every handler uses and is unchanged.
- The test app's `open-window` handler is one call, left inline in `main.ts` (Ziggy `CLAUDE.md`, Code Style) and covered by `28-external-links`.

## Smoke Tests

- Ziggy `28-external-links`, on every platform: a plain link, a `target="_blank"` link and `window.open`, each clicked with no user gesture, leave the test app's frontend loaded with the marker it was given; on Linux and Android each address is seen reaching the system's handler for its scheme.
- Photosphere `67-external-links`: the About page's website link, and on desktops the Help menu item, leave the About page shown; on Linux and Android the address is seen reaching the system.
- Every existing scenario in Ziggy's `smoke-tests` still passes on Linux, since `XDG_CONFIG_HOME` is new to every Linux start.

## Verify

- Ziggy: `mise exec -C ../ziggy -- zig build`, `zig build test`, `bun run compile`, `bun run test` and `bun run test:android-shell` exit 0.
- Ziggy: `mise exec -C ../ziggy -- bun run test:smoke` exits 0 on Linux, `28-external-links` included. Output captured to `../ziggy/tmp/`.
- Ziggy: `mise exec -C ../ziggy -- bun run test:smoke:android -- 28` exits 0 when `adb devices` lists a serial as `device` at that moment.
- Photosphere: `mise exec -C . -- bun run compile` exits 0, and `67-external-links` passes on Linux against the build of step 8.
- `bash -n` passes over every new or edited shell script.
- CI-only: `28-external-links` on Windows, macOS and iOS (`test:smoke` on those hosts, `test:smoke:ios` on a Mac); Photosphere's `67-external-links` on Android, iOS, Windows and macOS, which runs once Photosphere takes a Ziggy release holding steps 2 to 5.

## Notes

- Photosphere has no native code for links: its native apps (`apps/photosphere/native/<platform>`) hand the web view to Ziggy's, and the "opens external links in the system browser" lines in their READMEs describe Ziggy's handlers. Its frontend uses `window.open` and `target="_blank"` (`about.tsx`, `navbar.tsx`, `news.tsx`, `toast-container.tsx`, `main.tsx`, `bug-report.ts`, `platform-provider-ziggy.tsx`). There is nothing of Photosphere's to replace; Ziggy's handling replaces the failure.
- Dev mode runs the frontend in an ordinary browser, where links behave as that browser makes them. It is outside this plan.
- Turning on automatic window opening cannot open a window: every native app's new-window handler either opens the address with the system's opener or drops it (Linux ignores the decision, Windows sets `Handled`, macOS and iOS return nil, Android loads it as a navigation that `shouldOverrideUrlLoading` decides). Only the app's own frontend runs in the web view, because the origin check blocks every other page.
- On Android, a `window.open` of the app's own address loads in place of the current page, because multiple windows are off. That is how it behaves today with a user's click; this plan does not change it.
- Photosphere takes Ziggy from the `v0.0.23` tag (`build.zig.zon`, the Gradle source dependency in `native/android/settings.gradle`, the Swift package in the Xcode projects). `zig build --fork=<path>` (listed by `zig build --help`) swaps in the local Ziggy for the Zig build only, so the local check of step 8 is on Linux. Step 8 lands in Photosphere together with its move to the Ziggy release holding steps 2 to 5; against `v0.0.23` the Help menu part of `67-external-links` fails on Linux, which is the failure this plan fixes.
- `28-external-links` exercises the failing case on every element: the test app's `click` command runs with no user gesture, which is the case the popup blocker drops.
- `XDG_DATA_HOME` already points at the scenario's directory on Linux, so the desktop file goes under it; `XDG_CONFIG_HOME` is added so GIO never reads the user's own `mimeapps.list`.
