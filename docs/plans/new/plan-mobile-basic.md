# Basic Mobile App (Android + iOS) with Capacitor 5

## Implementation Steps

- [x] 1. Android "Hello world" frontend + native project — `plan-mobile-basic/1-android-hello-world.md`
- [x] 2. iOS "Hello world" frontend + native project — `plan-mobile-basic/2-ios-hello-world.md`
- [ ] 3. Android real Photosphere UI reaching the About page — `plan-mobile-basic/3-android-real-ui.md`
- [ ] 4. iOS real Photosphere UI reaching the About page — `plan-mobile-basic/4-ios-real-ui.md`

> Documentation: the only docs needed are a per-package `README.md` in each frontend, modeled on `capacitor-example/README.md` (pre-reqs, setup, Android, iOS run commands). No other docs (no `docs/mobile-apps.md`, no wiki pages).

## Overview
Photosphere has web (`dev-frontend`), desktop (`desktop-frontend` + Electron `desktop`), and CLI interfaces, but no mobile build. This plan adds Capacitor 5 mobile apps for Android and iOS. Each platform gets its **own** React frontend package (following the `desktop-frontend` convention) and its own native project. It is delivered in two phases. Phase 1 stands up the two frontend packages, each rendering only "Hello world", plus the generated Android and iOS native projects, so the integration into the monorepo can be seen and each shell tested on device/emulator. Phase 2 swaps the placeholder "Hello world" in each frontend for the real Photosphere UI from `packages/user-interface` (via a stubbed mobile platform provider, since background tasks and native bridges do not work on mobile yet) with the single goal of loading the UI and navigating to the About page on both platforms. Capacitor 5 (not 6/7) is required due to current macOS toolchain limits.

## Issues
<!-- Populated later by plan:check -->

## Steps

### Phase 1 — Two "Hello world" mobile shells

#### Android frontend package

1. Create the workspace package directory `apps/android-frontend/`. It is a self-contained Capacitor package holding the Android React frontend and the generated Android native project. It is picked up automatically by the root `package.json` `workspaces` entry `apps/*`.

2. Create `apps/android-frontend/package.json` (mirror `apps/desktop-frontend/package.json` naming so root `bun --filter '*' <script>` picks up the scripts):
   - `"name": "android-frontend"`, `"version": "1.0.0"`, `"private": true`, `"type": "module"`.
   - Scripts:
     - `"compile": "tsc --noEmit"`
     - `"bundle": "vite build"` (Vite builds the web frontend into `dist/`)
     - `"test": "jest --passWithNoTests"`
     - `"clean": "rm -rf dist build tsconfig.tsbuildinfo"`
     - `"sync": "vite build && cap sync android"`
     - `"open:android": "cap open android"`
     - `"run:android": "cap run android"`
   - `dependencies`: `react@^18.2.0`, `react-dom@^18.2.0`, `@capacitor/core@^5.7.4`, `@capacitor/android@^5.7.4`.
   - `devDependencies`: `@capacitor/cli@^5.7.4`, `@vitejs/plugin-react@^4.2.1`, `vite@^5.1.6`, `typescript@^5.3.3`, `jest@^29.0.1`, `ts-jest@^29.0.5`, `@types/jest@^29.4.0`, `@types/react@^18.2.43`, `@types/react-dom@^18.2.17`, `jest-environment-jsdom@^29.4.1`, `@testing-library/react`, `@testing-library/jest-dom`.
   - Pin all `@capacitor/*` packages to the `^5.x` line. Do not allow Capacitor 6/7.

3. Create `apps/android-frontend/capacitor.config.ts` (typed with `CapacitorConfig`):
   - `appId`: `"au.com.codecapers.photosphere"` (placeholder; see Notes).
   - `appName`: `"Photosphere"`.
   - `webDir`: `"dist"` (Vite build output copied into the native project by `cap sync`).
   - `bundledWebRuntime: false`, empty `plugins: {}`.

4. Create `apps/android-frontend/index.html` modeled on `apps/dev-frontend/index.html`: `<div id="app"></div>` root, mobile viewport meta `viewport-fit=cover, width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no`, `<script type="module" src="./src/index.tsx"></script>`, title "Photosphere".

5. Create `apps/android-frontend/vite.config.ts` modeled on `apps/desktop-frontend/vite.config.ts`: `plugins: [react()]`, `base: './'` (Capacitor serves from a non-http origin so relative asset paths are required), `build: { outDir: 'dist', emptyOutDir: true, sourcemap: true }`.

6. Create `apps/android-frontend/tsconfig.json` modeled on `apps/desktop-frontend/tsconfig.json` (`composite: true`, `jsx: "react-jsx"`, `module: "ESNext"`, `moduleResolution: "bundler"`, `rootDir: "./src"`, `noEmit: true`, `strict: true`, `skipLibCheck: true`, `lib: ["ES2020","DOM","DOM.Iterable"]`).

7. Create `apps/android-frontend/jest.config.js` modeled on `apps/desktop-frontend/jest.config.js`, but `testEnvironment: 'jsdom'` (the Hello-world render test needs a DOM). Keep `modulePathIgnorePatterns` for `dist`/`build`. No `moduleNameMapper` needed in Phase 1.

8. Create `apps/android-frontend/src/index.tsx` modeled on `apps/dev-frontend/src/index.tsx`: import React and `createRoot`, import `{ App } from "./app"`, get `document.getElementById('app')`, throw if missing, `createRoot(container).render(<App />)`. No fontawesome/tailwind imports in Phase 1.

9. Create `apps/android-frontend/src/app.tsx` with a minimal exported named function `App` returning `<h1>Hello world</h1>` inside a root `<div>`. Add a `//` comment block above `App` per code style rules.

10. Generate the Android native project: run `bun install` from repo root first (so `@capacitor/*` and the CLI resolve through the workspace), run `vite build` in `apps/android-frontend` so `dist/` exists, then from `apps/android-frontend` run `npx cap add android`. This creates `apps/android-frontend/android/`.

11. Add `apps/android-frontend/.gitignore` (modeled on `capacitor-basic-example/.gitignore` plus Capacitor's generated ignores) to exclude `node_modules/`, `dist/`, `.gradle/`, build outputs, `*.map`, `.DS_Store`. Keep the native project sources (`android/`) tracked.

11a. Add `apps/android-frontend/README.md` modeled on `/home/ash/projects/photosphere/capacitor-example/README.md`: pre-reqs (Node/Bun, Android Studio, Xcode + CocoaPods for iOS), setup, and the Android/iOS run commands adapted to this package's `bun run` scripts. This is the only documentation produced by the plan.

#### iOS frontend package

12. Create the workspace package directory `apps/ios-frontend/`, self-contained Capacitor package holding the iOS React frontend and the generated iOS native project.

13. Create `apps/ios-frontend/package.json`, identical in shape to `apps/android-frontend/package.json` but:
    - `"name": "ios-frontend"`.
    - `dependencies` use `@capacitor/ios@^5.7.4` instead of `@capacitor/android`.
    - Scripts use the iOS variants: `"sync": "vite build && cap sync ios"`, `"open:ios": "cap open ios"`, `"run:ios": "cap run ios"`.
    - Same `^5.x` Capacitor pin.

14. Create `apps/ios-frontend/capacitor.config.ts`, `apps/ios-frontend/index.html`, `apps/ios-frontend/vite.config.ts`, `apps/ios-frontend/tsconfig.json`, `apps/ios-frontend/jest.config.js`, `apps/ios-frontend/src/index.tsx`, `apps/ios-frontend/src/app.tsx`, `apps/ios-frontend/.gitignore`, and `apps/ios-frontend/README.md` — same content as the Android frontend equivalents (steps 3–9, 11, 11a). The `app.tsx` again renders only `<h1>Hello world</h1>`. Add `ios/App/Pods/` to the `.gitignore`.

15. Generate the iOS native project: from `apps/ios-frontend` run `vite build` then `npx cap add ios`. This creates `apps/ios-frontend/ios/`. Note: the `pod install` step run by `cap add ios` requires CocoaPods/macOS; on the Linux dev box it may warn or partially complete. If it fails, still commit the generated `ios/App` scaffolding and document that `pod install` / `cap sync ios` must be completed on macOS. Capture this in Notes.

#### Root wiring

16. Add root convenience scripts to the top-level `package.json` `scripts`:
    - `"sync:android": "bun run --filter=android-frontend sync"`.
    - `"sync:ios": "bun run --filter=ios-frontend sync"`.
    - Do not wire mobile into `test:all` yet (no device automation available in CI).
    - Confirm the root `.gitignore` does not exclude the new `apps/android-frontend` / `apps/ios-frontend` sources (the stale `apps/mobile/frontend/build` entry does not match this layout and can be left as-is).

### Phase 2 — Real Photosphere UI reaching the About page (both frontends)

> Apply the following to **both** `apps/android-frontend` and `apps/ios-frontend`. The frontend code is identical between the two packages; only the native project and the Capacitor platform dependency differ.

17. Add UI dependencies to each frontend's `package.json`:
    - `dependencies`: add `user-interface: "workspace:*"`, `task-queue: "workspace:*"`, `utils: "workspace:*"`, `react-router-dom@^6.4.1`, `uuid@^9.0.1`.
    - `devDependencies`: add `@fortawesome/fontawesome-free@^6.2.1`, `tailwindcss@^3.4.1`, `postcss@^8.4.35`, `autoprefixer@^10.4.18`, `@types/uuid@^9.0.8`.
    - Run `bun install` from repo root to link workspaces.

18. Add Tailwind config `tailwind.config.js`, `postcss.config.js`, and `.postcssrc` to each frontend, modeled exactly on `desktop-frontend` (content globs must include `"./src/**/*.{html,js,ts,jsx,tsx}"` and `"../../packages/user-interface/src/**/*.{html,js,ts,jsx,tsx}"`).

19. Create `src/tailwind.css` in each frontend (copy from `apps/desktop-frontend/src/tailwind.css`).

20. Create `src/lib/mobile-queue-backend.ts` in each frontend implementing `IQueueBackend` from `task-queue`:
    - Class `MobileQueueBackend implements IQueueBackend`.
    - `addTask` returns the provided `taskId` or a generated id string and does nothing else (no worker on mobile yet).
    - `onTaskAdded`, `onTaskComplete`, `onTaskMessage`, `onAnyTaskMessage`, `onTasksCancelled` register the callback and return a no-op unsubscribe function.
    - `cancelTasks` and `shutdown` are no-ops.
    - Add `//` comment blocks above the class and each method explaining that mobile background task execution is not yet implemented.

21. Create `src/lib/platform-provider-mobile.tsx` in each frontend, modeled on `apps/dev-frontend/src/lib/platform-provider-web.tsx` but with no WebSocket dependency:
    - Component `PlatformProviderMobile({ children })`.
    - Implement every member of `IPlatformContext` as a stub: callbacks return no-op unsubscribe functions; data getters return empty arrays / `undefined` / sensible defaults (e.g. `checkTools` returns all-available, `checkDatabaseExists` returns `false`).
    - Build `config` via `createConfig` backed by an in-memory `Map`.
    - Wrap children in `ConfigContextProvider` then `PlatformContextProvider`.
    - Add `//` comment blocks above the component and an inline note that all native integrations are stubbed for now.

22. Rewrite `src/app.tsx` in each frontend to mount the real UI, modeled on `apps/dev-frontend/src/app.tsx` but without the `useWebSocket` gate:
    - Import providers and `Main`, `StoriesPage` from `user-interface`; `setQueueBackend` from `task-queue`; `RandomUuidGenerator` from `utils`.
    - Instantiate `MobileQueueBackend`, call `setQueueBackend(...)`.
    - Render `HashRouter` with the same provider nesting as `dev-frontend` (`UuidGeneratorProvider` → `PlatformProviderMobile` → `ApiContextProvider` → `AppContextProvider` → `ToastContextProvider` → `AssetDatabaseProvider` → `ImportContextProvider` → `GalleryContextProvider` → `DeleteConfirmationContextProvider` → `SearchContextProvider` → `GalleryLayoutContextProvider` → `Main isMobile={true} initialTheme="system"`).
    - Pass a placeholder `restApiUrl` (e.g. `"http://localhost:3001"`) to `AssetDatabaseProvider`; unused while no database is open.
    - Keep the `/stories` route for parity with the other frontends.
    - Set `isMobile={true}`.

23. Update `src/index.tsx` in each frontend to import the UI styles: add `import '@fortawesome/fontawesome-free/css/all.css'` and `import './tailwind.css'` (mirroring `dev-frontend`).

24. Update each frontend's `jest.config.js` `moduleNameMapper` to map workspace packages to their TypeScript sources the same way `desktop-frontend` maps `task-queue` (add `^task-queue$`, `^user-interface$`, `^utils$` as needed). Confirm `testEnvironment: 'jsdom'`.

25. Rebuild and re-sync each frontend: run `vite build` then `cap sync android` (Android frontend) / `cap sync ios` (iOS frontend) so the real UI bundle is copied into each native project.

## Unit Tests

> Tests below are duplicated in both `apps/android-frontend/src/test/` and `apps/ios-frontend/src/test/` since each frontend is its own package.

- `app.test.tsx` (Phase 1): render `<App />` with `@testing-library/react` and assert the text `Hello world` is in the document. Automated stand-in for "see Hello world on device".
- `mobile-queue-backend.test.ts` (Phase 2): verify `MobileQueueBackend.addTask` returns the supplied `taskId`, returns a non-empty string when none is supplied, that the `on*` registration methods return callable no-op unsubscribe functions, and that `cancelTasks`/`shutdown` do not throw.
- `platform-provider-mobile.test.tsx` (Phase 2): render a child inside `PlatformProviderMobile` and assert it renders; assert the in-memory `config` round-trips a set/get value.
- `about-navigation.test.tsx` (Phase 2): render `<App />`, set `window.location.hash = '#/about'`, and assert the About page heading `About Photosphere` (from `packages/user-interface/src/pages/about.tsx`) appears. Automated stand-in for "switch to the About page on device".

## Smoke Tests

Add a `smoke-tests.sh` to each frontend (invoked via `bun run`, never called directly per repo rules — wire root scripts `"test:android": "cd ./apps/android-frontend && ./smoke-tests.sh"` and `"test:ios": "cd ./apps/ios-frontend && ./smoke-tests.sh"`). No emulator exists in this environment, so the smoke tests are build/bundle based, not device based:

- Run `compile` (tsc) and assert exit 0.
- Run `bundle` (Vite build) and assert `dist/index.html` and a hashed JS bundle exist.
- Phase 1: assert the built JS bundle contains the string `Hello world`.
- Phase 2: assert the built JS bundle references the About page (grep for `About Photosphere`).
- Run `cap sync` (Android: `cap sync android`; iOS: `cap sync ios`) and assert exit 0 and that web assets were copied into the native public dir (Android: `android/app/src/main/assets/public/`; iOS: the `ios/App` public dir if `ios/` generated successfully).
- Document inside each script (comment) that on-device launch (`cap run android` / `cap run ios`) requires Android Studio / Xcode and is performed outside automated CI.

## Verify

- `bun install` from repo root succeeds and links the new `android-frontend` and `ios-frontend` workspaces.
- `bun run compile` (root) succeeds with both new packages included.
- `bun run test` (root unit tests) passes, including the new tests in both frontends.
- `bun run test:android` and `bun run test:ios` pass: compile + Vite build + `cap sync` succeed and the bundle-content assertions pass.
- `bun run --filter=android-frontend bundle` and `bun run --filter=ios-frontend bundle` each produce a `dist/` with `index.html` and JS assets.
- `apps/android-frontend/android/` exists and `cap sync android` reports the platform updated.
- `apps/ios-frontend/ios/App/` scaffolding exists (note macOS-only `pod install` caveat if it could not complete on Linux).
- Run the full suite `bun run test:all` and confirm no regressions in existing packages.
- Manual-on-device confirmation (Hello world in Phase 1, About page in Phase 2) is out of automated scope and left to the developer with `cap run android` / `cap run ios`; the automated render tests above cover the same assertions headlessly.

## Notes

- **Two separate per-platform frontends:** Per the request, Android and iOS each get their **own** React frontend package — `apps/android-frontend` and `apps/ios-frontend` — mirroring the `desktop-frontend` naming and structure. Each package is self-contained: its own React frontend (`src/`), Capacitor config, and generated native project (`android/` or `ios/` respectively). The Phase 2 frontend code is identical between the two; only the native project and the `@capacitor/{android,ios}` dependency differ.
- **Capacitor version pin:** Hard-pin `@capacitor/*` and `@capacitor/cli` to `^5.7.4` in both packages. Do not upgrade to 6/7 — required by the current macOS toolchain limitation.
- **Bun vs npm:** The example uses npm; this repo uses Bun workspaces. `@capacitor/cli` is invoked via `npx cap ...` from within each frontend; dependencies resolve through the hoisted root `node_modules`. Verify `cap` resolves after `bun install`.
- **iOS on Linux:** `cap add ios` runs `pod install`, which needs CocoaPods on macOS. On the Linux dev box this may not fully complete. Commit the generated `ios/App` scaffolding regardless and finish `pod install` / `cap sync ios` on macOS. The iOS smoke test only conditionally asserts the asset copy when `ios/` exists.
- **Background tasks / native bridges are stubbed:** `MobileQueueBackend` and `PlatformProviderMobile` are intentionally no-op/in-memory. Most real functionality (import, sync, file pickers, vault, share) will not work on mobile yet. Phase 2's only success criterion is: the UI loads and the About page renders. This is expected and acceptable.
- **`isMobile={true}`:** Phase 2 is the first real consumer of the `isMobile` branch in `packages/user-interface/src/main.tsx`. Watch for mobile-layout code paths that assume capabilities the stub provider does not supply; if the About route cannot be reached because an earlier screen hard-requires a database/native call, add the minimal stub return needed (do not modify `user-interface` beyond what is required to reach `/about`).
- **Shared frontend code duplication:** Because the Phase 2 `app.tsx`, `index.tsx`, `platform-provider-mobile.tsx`, and `mobile-queue-backend.ts` are identical across both frontends, they are duplicated per package. If this duplication becomes a maintenance burden later, the shared pieces can be extracted into a small `packages/mobile-frontend-shared` package, but that is out of scope here.
- **App id:** `au.com.codecapers.photosphere` is a placeholder. Reconcile with any existing desktop bundle identifier before any store build.
