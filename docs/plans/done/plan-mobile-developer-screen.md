# Mobile Developer Screen

## Overview
On desktop, Stories (the hand-rolled component browser at the `/stories` route) is opened from the native Electron "Developer" menu. Mobile has no menu bar, so there is currently no way to reach Stories or any other developer tool from the mobile UI, even though the `/stories` route is already registered in `apps/android-frontend/src/app.tsx` and `apps/ios-frontend/src/app.tsx`. This plan adds a hidden activation gesture (tapping the version label on the About page 4 times) that turns on a persistent "developer mode" flag. While developer mode is on, a new "Developer" entry appears in the shared `LeftSidebar` and navigates to a new dedicated `/developer` screen that lists developer tools (Stories now, more later) and includes a button to exit developer mode. Because the affected UI is the shared `user-interface` package, the feature works on all platforms (web, desktop, mobile) with no per-app code.

## Issues
<!-- Leave empty - populated later by plan:check -->

## Steps

1. **Add the tap-counter helper.** Create `packages/user-interface/src/lib/tap-counter.ts`. This holds the pure logic for detecting a rapid multi-tap, kept separate from React so it is unit testable. Define:
   - `interface ITapState { count: number; lastTapTime: number; }` (with the required `//` field comments) describing the running tap state.
   - `interface ITapResult { state: ITapState; triggered: boolean; }` describing the result of registering one tap: the updated state and whether the threshold was just reached.
   - `function registerTap(previous: ITapState, now: number, windowMs: number, threshold: number): ITapResult`. Behaviour: if `now - previous.lastTapTime > windowMs`, restart the streak at count `1`; otherwise increment `previous.count` by `1`. Set `lastTapTime` to `now`. When the resulting count is `>= threshold`, return `triggered: true` and reset the returned `state.count` to `0` (so a fresh streak is needed to trigger again); otherwise `triggered: false`.
   - Export `DEVELOPER_MODE_TAP_THRESHOLD = 4` and `DEVELOPER_MODE_TAP_WINDOW_MS` (e.g. `2000`) as named constants with `//` comment blocks, used by the About page.
   - The file must type-check and its unit test (step listed below) must pass.

2. **Add the developer-mode context.** Create `packages/user-interface/src/context/developer-mode-context.tsx`, modeled on `config-context.tsx`. Define:
   - `const DEVELOPER_MODE_CONFIG_KEY = "developerMode";` named constant (the config persistence key).
   - `interface IDeveloperModeContext { developerMode: boolean; enableDeveloperMode: () => void; disableDeveloperMode: () => void; }` with `//` field comments.
   - `interface IDeveloperModeContextProviderProps { children: ReactNode | ReactNode[]; }`.
   - `function DeveloperModeContextProvider({ children })`: uses `useConfig()`; holds `developerMode` in `useState<boolean>(false)`; on mount reads `config.get<boolean>(DEVELOPER_MODE_CONFIG_KEY)` and sets state from it (default `false`); `enableDeveloperMode` sets state `true`, persists `config.set(DEVELOPER_MODE_CONFIG_KEY, true)`, and emits `log.event("Developer mode enabled")`; `disableDeveloperMode` sets state `false`, persists `config.set(DEVELOPER_MODE_CONFIG_KEY, false)`, and emits `log.event("Developer mode disabled")`. Persistence calls are fire-and-forget with `.catch(...)` logging, matching the `CollapsibleSection` pattern (no new exception handling beyond logging).
   - `function useDeveloperMode(): IDeveloperModeContext` that reads the context and throws if the provider is missing, mirroring `useConfig`.
   - Export the provider, the hook, the context type, and the config-key constant.
   - File must type-check. As a React context it is not unit tested; it is covered by the smoke test.

3. **Mount the provider inside `Main`.** Edit `packages/user-interface/src/main.tsx`. Import `DeveloperModeContextProvider`. In the outer `Main` wrapper (the exported `Main` at the bottom that wraps `__Main`), wrap `__Main` with `<DeveloperModeContextProvider>` so the navbar, sidebar drawer, and all inner routed pages (including `AboutPage` and the new `DeveloperPage`) share one reactive developer-mode value. It must sit inside the existing config provider (which is already an ancestor of `Main` on every platform, since `useConfig` already works inside `Main`). Type-check must pass.

4. **Create the developer screen.** Create `packages/user-interface/src/pages/developer.tsx` exporting `function DeveloperPage(): JSX.Element`, modeled on `pages/about.tsx` for layout and on `components/left-sidebar.tsx` for the Joy `List`/`ListItem`/`ListItemButton` menu idiom. Contents:
   - `useNavigate()` and `useDeveloperMode()`.
   - A page heading "Developer".
   - A `List` of developer tools. First (and currently only) tool: a `ListItem`/`ListItemButton` labelled "Stories" with `data-id="developer-tool-stories"` whose `onClick` calls `navigate('/stories')`. Add a `//` comment noting future tools are added to this list.
   - A separate "Exit developer mode" button (`data-id="developer-exit"`) whose `onClick` calls `disableDeveloperMode()` then `navigate('/gallery')` (leaving the now-hidden screen).
   - Give the root element `data-id="developer-page"`.
   - As a React component it is not unit tested; it is covered by the smoke test. Type-check must pass.

5. **Register the `/developer` route.** Edit `packages/user-interface/src/main.tsx`. Import `DeveloperPage` from `./pages/developer`. Add `<Route path="/developer" element={<DeveloperPage />} />` to the inner `<Routes>` block (alongside `/about`, `/news`, etc., near `main.tsx:338`). The route lives inside `Main` so the developer screen keeps the standard navbar and sidebar. Type-check must pass.

6. **Add the conditional sidebar entry.** Edit `packages/user-interface/src/components/left-sidebar.tsx`. Import `useDeveloperMode` and a suitable icon (e.g. `DeveloperMode` or `Code` from `@mui/icons-material`). Call `const { developerMode } = useDeveloperMode();`. In the bottom group `List` (the block around `left-sidebar.tsx:351-391`, with Manage Databases / Manage Secrets / Configuration), conditionally render, only when `developerMode` is true, a `NavLink to="/developer"` entry modeled exactly on the existing About `NavLink` (active styling via `activeNavItemSx`, `onClick={() => setSidebarOpen(false)}`), labelled "Developer", with `data-id="sidebar-developer"`. Type-check must pass; behaviour covered by the smoke test.

7. **Make the About version label the activation gesture.** Edit `packages/user-interface/src/pages/about.tsx`. Import `useRef`, `registerTap`, `DEVELOPER_MODE_TAP_THRESHOLD`, `DEVELOPER_MODE_TAP_WINDOW_MS`, and `useDeveloperMode`. Add a `useRef<ITapState>({ count: 0, lastTapTime: 0 })`. Convert the existing `<p>Version {version}</p>` (about.tsx:25) into a clickable element with `data-id="about-version"` and an `onClick` that: reads `Date.now()`, calls `registerTap(ref.current, now, DEVELOPER_MODE_TAP_WINDOW_MS, DEVELOPER_MODE_TAP_THRESHOLD)`, stores the returned `state` back into the ref, and when `triggered` is true calls `enableDeveloperMode()`. Keep the visual appearance unchanged (no obvious affordance) but add `cursor: default` styling so it does not look like a button. Type-check must pass; behaviour covered by the smoke test.

8. **Export new symbols from the package barrel as needed.** Edit `packages/user-interface/src/index.tsx` only if the smoke-test or app entries need them. `DeveloperPage` is referenced only inside `main.tsx`, so it does not need exporting. No app-entry (`apps/*-frontend/src/app.tsx`) changes are required because `/developer` is an inner `Main` route and `/stories` already exists in every app entry. Confirm by grep that no app entry needs editing; the whole-project compile must pass.

9. **Add the smoke test.** Create `apps/desktop/smoke-tests/<n>-developer-screen/test.sh` modeled on `apps/desktop/smoke-tests/1-load-fixture/test.sh` (pick the next free number). The shared `user-interface` code under test is identical across platforms, so the Electron smoke harness validates the mobile behaviour too. The script must: start the app and `wait_for_ready`; `send_command navigate '{"page":"/about"}'`; issue `send_command click '{"dataId":"about-version"}'` four times; `wait_for_log` for `Developer mode enabled`; `send_command navigate '{"page":"/developer"}'` (or click `sidebar-developer` after opening the drawer) and assert the developer page is present via `get-value` on `data-id="developer-page"` or a tool label; `send_command click '{"dataId":"developer-tool-stories"}'` and assert the Stories page rendered (e.g. `get-value` on a Stories-page test id, or assert the hash route changed); navigate back to `/developer`, `send_command click '{"dataId":"developer-exit"}'`, and `wait_for_log` for `Developer mode disabled`; finally `check_no_errors`. Register the test in the desktop smoke-test runner/list the same way existing numbered tests are registered. The test must pass via `bun run test:electron`.

## Unit Tests
- `packages/user-interface/src/test/tap-counter.test.ts` for `registerTap` (use `test(`, not `it(`):
  - Single tap returns `count: 1`, `triggered: false`.
  - Reaching the threshold within the window returns `triggered: true` and resets `state.count` to `0`.
  - A tap after `windowMs` has elapsed restarts the streak at `count: 1` (does not trigger even if the prior count was high).
  - Consecutive taps within the window increment the count up to but not past the threshold without triggering.
  - After a trigger, the next tap starts a fresh streak at `count: 1`.

No unit tests are added for `DeveloperModeContextProvider`, `useDeveloperMode`, `DeveloperPage`, the `LeftSidebar` change, or the `AboutPage` change, because the project rule excludes React components, contexts, and hooks from unit testing (they are covered by the smoke test).

## Smoke Tests
- New `apps/desktop/smoke-tests/<n>-developer-screen/test.sh` (Step 9) covering the full path end to end: hidden gesture enables developer mode, the `/developer` screen is reachable and lists Stories, Stories opens from it, and the exit button disables developer mode. Asserts via `wait_for_log` on the `Developer mode enabled` / `Developer mode disabled` events and `get-value`/route checks, with `check_no_errors` at the end.
- This single shared-UI smoke test covers the mobile requirement because `LeftSidebar`, `AboutPage`, `DeveloperPage`, and the developer-mode context all live in the shared `user-interface` package and run unchanged on mobile.

## Verify
- `bun run compile` succeeds with no TypeScript errors.
- `bun run test` passes, including the new `tap-counter.test.ts`.
- `bun run test:electron` passes, including the new `developer-screen` smoke test.
- Grep confirms no `apps/*-frontend/src/app.tsx` changes were required and that `/stories` is still routed in every app entry.

## Notes
- Decision (confirmed with user): activation is a hidden 4-tap gesture on the About page version label; it enables a persistent developer-mode flag (not a direct navigation). Threshold is 4 taps (the user explicitly reduced it from the usual 7).
- Decision: developer mode is shown on all platforms, not gated to mobile. This avoids threading `isMobile` into the sidebar and matches the existing always-visible "Run background task" dev affordance. Desktop therefore gains a second route to Stories alongside its native Developer menu, which is acceptable.
- Decision: the developer screen is a dedicated `/developer` page (a menu of tools), so future developer tools are added by appending to the `List` in `pages/developer.tsx` with no further routing or sidebar work.
- The flag is persisted with the existing `IConfig` (`config.set`/`config.get`) under key `developerMode`, the same store `CollapsibleSection` uses, so it survives app restarts on every platform.
- The developer-mode state is shared reactively via a React context (`DeveloperModeContextProvider` mounted in `Main`) rather than re-reading config on each sidebar open, so toggling the flag updates the sidebar immediately.
- `/developer` is an inner `Main` route (keeps navbar + sidebar), whereas `/stories` remains a top-level route outside the provider stack (each story owns its providers); navigating between them works because both are under the same `HashRouter`.
- The smoke test relies on the existing `test-driver` commands (`navigate`, `click`, `get-value`, `wait_for_log`) and on the new `data-id` attributes added to the version label, sidebar entry, developer page, Stories tool, and exit button.

## As-built deviations

The implementation departed from the plan in a few places to avoid unnecessary scaffolding and to fix a related bug:
- The tap logic was inlined directly into `pages/about.tsx` (a `useRef` plus a few lines) instead of a separate `lib/tap-counter.ts` module with its own unit test. It is covered by the smoke test.
- The developer-mode flag was folded into the existing `AppContext` (`developerMode` / `enableDeveloperMode` / `disableDeveloperMode`) rather than a new `developer-mode-context.tsx`. `AppContext` is already the app-wide reactive layer mounted above `Main` on every platform, so no new provider wiring was needed.
- A success toast ("Developer mode enabled") is shown from `about.tsx` when the gesture fires, giving the user feedback that the otherwise-invisible 4-tap had an effect.
- The smoke test leaves the top-level `/stories` route via its in-page back link (given a `data-id`) before navigating back to `/developer`, because the desktop `navigate` command is handled inside `Main` and does not work while `Main` is unmounted on `/stories`.
- Fixed a pre-existing mobile bug: the generic `IConfig` store on mobile was an in-memory `Map` that did not survive app restarts, so developer mode (and theme, sidebar-collapse state, etc.) was lost on restart. Mobile config now persists to WebView `localStorage` via new `getConfigValue` / `setConfigValue` helpers in `mobile-config-store.ts` (with unit tests), matching how databases and secrets are already persisted.
