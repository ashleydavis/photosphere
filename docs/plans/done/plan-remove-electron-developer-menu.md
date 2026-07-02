# Remove the Electron Developer Menu and Move Its Options to the Developer Page

## Overview
The Electron build has a top-level "Developer" application menu (`apps/desktop/src/main.ts`, `createMenu()`) holding five items: Reload, Force Reload, Toggle Developer Tools, Stories, and Show FPS Indicator. A hidden in-app developer page now exists (`packages/user-interface/src/pages/developer.tsx`, reached by the 4-tap version gesture). This plan removes the Developer application menu entirely and moves its real options onto the developer page so they work across desktop and mobile from one shared component. Stories already lives on the page. "Show FPS Indicator" becomes a config-backed toggle that works on desktop and mobile with no IPC, by folding the setting into `AppContext` (the same pattern already used for `developerMode`). "Toggle Developer Tools" is added as a page item that toggles native Electron dev tools on desktop and the embedded Eruda console on web/mobile, so it works on every platform and nothing has to be hidden. It reuses the existing generic `main-command` IPC channel and its existing `toggle-devtools` action (`main.ts:433-447`): no new IPC channel is added. The renderer reaches it through a new method on the existing platform abstraction so no platform-specific code is added to the shared `user-interface` package. The built-in Reload / Force Reload roles are standard Electron affordances and are dropped with the menu (not re-added). After the menu is gone, `main.ts` is cleaned up to delete the now-dead submenu, the FPS menu-checkbox state, the unused `node-api` FPS getters/setters, and the dead `menu-action` dispatch cases.

## Issues
<!-- Populated later by plan:check -->

## Steps

1. Fold the FPS setting into `AppContext` (`packages/user-interface/src/context/app-context.tsx`).
   - Add a config key constant near `DEVELOPER_MODE_CONFIG_KEY` (line 10): `const SHOW_FPS_INDICATOR_CONFIG_KEY = "showFpsIndicator";` (this is the exact key already read by `fps.tsx` and previously written by the menu, so existing persisted values carry over).
   - Add to `IAppContext` (after the developer-mode members, around line 84): `showFpsIndicator: boolean;` and `toggleShowFpsIndicator: () => void;`, each with a `//` doc comment.
   - In `AppContextProvider`, add `const [showFpsIndicator, setShowFpsIndicator] = useState<boolean>(false);` next to the `developerMode` state (line 110).
   - Add a `toggleShowFpsIndicator()` function modelled on `enableDeveloperMode`/`disableDeveloperMode` (lines 197-212): compute the next value from current state, call `setShowFpsIndicator(nextValue)`, persist via `config.set<boolean>(SHOW_FPS_INDICATOR_CONFIG_KEY, nextValue)` with the same `.catch(...log.exception...)` fire-and-forget pattern, and `log.event(...)`.
   - Add a load effect mirroring the developer-mode load effect (lines 220-226): `config.get<boolean>(SHOW_FPS_INDICATOR_CONFIG_KEY).then(value => { if (value !== undefined) setShowFpsIndicator(value); })`.
   - Add `showFpsIndicator` and `toggleShowFpsIndicator` to the `value` object (lines 244-258).
   - This file is a React context (not unit tested); behaviour is covered by the developer-screen smoke test in step 8. Confirm `bun run compile` passes.

2. Simplify the FPS overlay to read from `AppContext` (`packages/user-interface/src/components/fps.tsx`).
   - Replace the local `useState` plus the two `useEffect`s and the `useConfig`/`usePlatform` wiring (lines 14-51) with a single read: `const { showFpsIndicator } = useApp();` (import `useApp` from `../context/app-context`).
   - Remove the now-unused `useConfig`, `usePlatform`, `useState`, and `useEffect` imports.
   - Update the component doc comment (lines 7-11) to state it reflects the `showFpsIndicator` value from `AppContext`, dropping the mention of the `toggle-fps` menu action.
   - This file is a React component (not unit tested); covered by the smoke test in step 8. Confirm `bun run compile` passes.

3. Extract the Eruda dev-console toggle into a shared, platform-neutral helper.
   - Create `packages/user-interface/src/lib/dev-console.ts` exporting `toggleDevConsole(): void`, moving the Eruda `import`, the module-level `erudaInitialised` / `erudaVisible` flags, and the init/show/hide logic currently inlined in `stories-page.tsx` (lines 66-98). Eruda runs in any WebView/browser, so this is not Electron/Capacitor-specific and is allowed in the shared package. Add a `//` doc comment.
   - Refactor `stories-page.tsx` `toggleDevTools()` (lines 80-98) so its web/mobile branch calls `toggleDevConsole()`. Keep its desktop branch (`electronAPI.send("main-command", "toggle-devtools")`) as is, because the stories page is mounted outside the provider stack and cannot use the platform abstraction. Remove the now-unused Eruda import and module-level flags from `stories-page.tsx`.
   - Confirm `bun run compile` passes.

4. Add a `toggleDevTools` capability to the platform interface (`packages/user-interface/src/context/platform-context.tsx`).
   - Add `toggleDevTools: () => void;` to `IPlatformContext` near the other main-process-related members (around line 326), with a `//` doc comment noting it toggles native developer tools on desktop and the embedded dev console on web/mobile.
   - Confirm `bun run compile` flags every provider that must implement it (handled in step 5).

5. Implement `toggleDevTools` in all three platform providers, reusing the existing IPC channel and the shared helper.
   - Electron (`apps/desktop-frontend/src/lib/platform-provider-electron.tsx`): add `function toggleDevTools(): void { electronAPI.send('main-command', 'toggle-devtools'); }` and include `toggleDevTools` in the returned provider object (the object that exposes `onMenuAction`, near line 513). This reuses the existing generic `main-command` channel and its existing `toggle-devtools` action, so `main.ts` needs no change.
   - Web (`apps/dev-frontend/src/lib/platform-provider-web.tsx`): add `function toggleDevTools(): void { toggleDevConsole(); }` (import the helper from `user-interface`) and include it in the provider object.
   - Mobile (`packages/mobile-frontend/src/lib/platform-provider-mobile.tsx`): same as web, calling `toggleDevConsole()`, and include it in the provider object.
   - Confirm `bun run compile` passes for all frontends.

6. Add the FPS toggle and the Dev Tools item to the developer page (`packages/user-interface/src/pages/developer.tsx`).
   - Pull `showFpsIndicator` and `toggleShowFpsIndicator` from `useApp()` (already imported), and `toggleDevTools` from `usePlatform()` (add the `usePlatform` import). Do not reference `electronAPI` or Eruda directly here.
   - Inside the `<List>` (after the existing Stories `ListItem`, line 35) add a "Show FPS indicator" entry, `data-id="developer-tool-fps-toggle"`, rendering a Joy `Switch` reflecting `showFpsIndicator` whose change handler calls `toggleShowFpsIndicator()`.
   - Add a "Toggle developer tools" entry, `data-id="developer-tool-devtools"`, whose `onClick` calls `toggleDevTools()`. It works on every platform (native dev tools on desktop, Eruda on web/mobile), so it is shown on all platforms and nothing is hidden.
   - Keep the existing Stories entry and "Exit developer mode" button unchanged.
   - This file is a React component (not unit tested); covered by the smoke test in step 8. Confirm `bun run compile` passes.

7. Remove the Developer application menu and its FPS menu state (`apps/desktop/src/main.ts`).
   - Delete the `developerSubmenu` definition and the `template.push({ label: 'Developer', submenu: developerSubmenu })` block (lines 1606-1637).
   - Delete the `currentShowFpsIndicator` read used to seed the menu checkbox (around line 1353) and any reference left only for the menu.
   - Remove the now-unused `getShowFpsIndicator` / `setShowFpsIndicator` import from `node-api` (line 14) once nothing in `main.ts` references them.
   - Keep the existing generic `main-command` handler (lines 431-447) and its `toggle-devtools` action: the developer page now relies on it.
   - Leave the env-gated `fps-measurement` listener (lines 387-393) in place: it is perf logging, not menu wiring.
   - Run `grep -rn "getShowFpsIndicator\|setShowFpsIndicator" apps packages` to confirm whether the `node-api` functions are still used anywhere; if now unused everywhere, delete them in step 9 below.
   - Confirm `bun run compile` passes for the desktop app.

8. Extend the developer-screen smoke test (`apps/desktop/smoke-tests/23-developer-screen/test.sh`).
   - After reaching `/developer`, assert the FPS toggle item (`data-id="developer-tool-fps-toggle"`) is present, click it, and assert the FPS overlay rendered by `<FPSStats>` appears; toggle again and assert it disappears.
   - Assert the Dev Tools item (`data-id="developer-tool-devtools"`) is present and clickable. Clicking opens real DevTools, so assert presence and that the click does not error rather than asserting DevTools state (keep the test non-flaky).
   - Keep the existing 4-tap gesture, Stories navigation, and exit assertions.
   - Run `bun run test:electron -- 23` and confirm it passes.

9. Remove dead `menu-action` dispatch and unused `node-api` FPS helpers.
   - Run `grep -rn "open-stories\|toggle-fps" apps packages` to find every producer and consumer.
   - In `packages/user-interface/src/main.tsx`, remove the `'open-stories'` dispatch case (lines 223-225) only if no remaining producer sends it (the menu no longer does; the page navigates to `/stories` directly). If a smoke test or the test-control server injects `open-stories`, keep the case and record that in Notes.
   - Confirm nothing still references the `toggle-fps` menu action (it was handled only in `fps.tsx`, removed in step 2).
   - If step 7's grep showed `getShowFpsIndicator` / `setShowFpsIndicator` are unused everywhere, delete those functions from `node-api` and any now-dead config plumbing they used; update or remove their `node-api` unit tests so the suite stays green.
   - Confirm `bun run compile` passes across the repo.

## Unit Tests
- No new pure (non-React) function is introduced except `toggleDevConsole` in `packages/user-interface/src/lib/dev-console.ts`. Because it only drives the Eruda global (a DOM/WebView side effect) it is exercised by the smoke test in step 8 rather than a unit test; if a thin unit test is feasible it should assert that calling it twice flips an internal visible flag.
- All other changed surfaces are React contexts, components, hooks, or platform providers, which per project rules are not unit tested and are covered by the smoke tests below.
- If step 9 deletes `getShowFpsIndicator` / `setShowFpsIndicator` from `node-api`, update or remove the corresponding `node-api` unit tests so the suite still passes.

## Smoke Tests
- `apps/desktop/smoke-tests/23-developer-screen/test.sh` (desktop): 4-tap gesture enables developer mode; navigate to `/developer`; Stories item navigates to `/stories` and back; FPS toggle item shows and hides the FPS overlay; Dev Tools item is present and clicking it does not error; Exit developer mode returns to `/gallery`.
- Mobile smoke coverage (Android/iOS): on the developer page the FPS toggle is present and works, and the Dev Tools item is present (it toggles the Eruda console on mobile) and clicking it does not error.

## Verify
- `bun run compile` succeeds for the whole repo with no TypeScript errors.
- `bun run test` (unit tests) passes.
- `bun run test:electron` passes, including the updated `23-developer-screen` test.
- The mobile smoke tests that cover the developer page pass.
- `grep -rn "ipcMain" apps/desktop/src/main.ts` shows no new IPC channel was added (the `main-command` handler is reused, unchanged).
- `grep -rn "Developer" apps/desktop/src/main.ts` shows no remaining Developer application-menu definition.
- `grep -rn "getShowFpsIndicator\|setShowFpsIndicator\|toggle-fps" apps packages` shows no dead references remain (the only FPS path is `AppContext` -> config -> `fps.tsx`).

## Notes
- No new IPC channel is added. DevTools toggling reuses the existing generic `main-command` channel and its existing `toggle-devtools` action in `main.ts`, exactly as `stories-page.tsx` already does.
- Because the desktop path goes through the existing generic channel and the web/mobile path goes through the Eruda console, "Toggle Developer Tools" works on every platform, so no developer-page item needs to be hidden and the page needs no `isMobile` prop.
- The shared `dev-console.ts` helper holds only Eruda (a platform-neutral web console) and no Electron/Capacitor code, so it complies with the rule against platform-specific code in `packages/user-interface`. The Electron-specific `electronAPI.send` lives only in the desktop provider.
- "Show FPS Indicator" moves from menu-driven (node-api persistence plus a `toggle-fps` menu action) to config-driven reactive state in `AppContext`. On desktop this persists through `get-config`/`set-config`; on mobile through the `localStorage`-backed config store. The same `"showFpsIndicator"` key is reused so previously saved desktop values continue to apply.
- Reload and Force Reload were Electron built-in roles, not custom options, and are not reproduced on the page (per the request not to add reload). They are removed with the menu.
- Open question for `plan:check`: confirm whether the long-running cycle-stories smoke test (`bun run test:stories`) or the test-control server injects the `open-stories` menu action; if so, keep the `main.tsx` dispatch case rather than deleting it in step 9.
