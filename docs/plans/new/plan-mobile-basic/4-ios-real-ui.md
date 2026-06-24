# Step 4 — iOS real Photosphere UI reaching the About page

Phase 2 for iOS. Replace the "Hello world" placeholder in `apps/ios-frontend` with the real Photosphere UI from `packages/user-interface`, backed by a stubbed mobile platform provider and a no-op queue backend. The single success criterion is: the UI loads and the About page renders. The frontend code is identical to the Android frontend from Step 3; only the native project and the `@capacitor/ios` dependency differ.

## Scope

Source: `plan-mobile-basic.md` Phase 2 (steps 17–25) applied to `apps/ios-frontend`. Background tasks and native bridges are intentionally stubbed.

## Work

1. Add UI dependencies to `apps/ios-frontend/package.json`:
   - `dependencies`: add `user-interface: "workspace:*"`, `task-queue: "workspace:*"`, `utils: "workspace:*"`, `react-router-dom@^6.4.1`, `uuid@^9.0.1`.
   - `devDependencies`: add `@fortawesome/fontawesome-free@^6.2.1`, `tailwindcss@^3.4.1`, `postcss@^8.4.35`, `autoprefixer@^10.4.18`, `@types/uuid@^9.0.8`.
   - Run `bun install` from repo root to link workspaces.

2. Add Tailwind config `tailwind.config.js`, `postcss.config.js`, and `.postcssrc` to `apps/ios-frontend`, modeled exactly on `desktop-frontend` (content globs must include `"./src/**/*.{html,js,ts,jsx,tsx}"` and `"../../packages/user-interface/src/**/*.{html,js,ts,jsx,tsx}"`).

3. Create `apps/ios-frontend/src/tailwind.css` (copy from `apps/desktop-frontend/src/tailwind.css`).

4. Create `apps/ios-frontend/src/lib/mobile-queue-backend.ts` implementing `IQueueBackend` from `task-queue` — identical to the Android version from Step 3:
   - Class `MobileQueueBackend implements IQueueBackend`.
   - `addTask` returns the provided `taskId` or a generated id string and does nothing else.
   - `onTaskAdded`, `onTaskComplete`, `onTaskMessage`, `onAnyTaskMessage`, `onTasksCancelled` register the callback and return a no-op unsubscribe function.
   - `cancelTasks` and `shutdown` are no-ops.
   - Add `//` comment blocks above the class and each method explaining that mobile background task execution is not yet implemented.

5. Create `apps/ios-frontend/src/lib/platform-provider-mobile.tsx` — identical to the Android version from Step 3:
   - Component `PlatformProviderMobile({ children })`.
   - Implement every member of `IPlatformContext` as a stub: callbacks return no-op unsubscribe functions; data getters return empty arrays / `undefined` / sensible defaults (e.g. `checkTools` returns all-available, `checkDatabaseExists` returns `false`).
   - Build `config` via `createConfig` backed by an in-memory `Map`.
   - Wrap children in `ConfigContextProvider` then `PlatformContextProvider`.
   - Add `//` comment blocks above the component and an inline note that all native integrations are stubbed for now.

6. Rewrite `apps/ios-frontend/src/app.tsx` to mount the real UI — identical to the Android version from Step 3:
   - Import providers and `Main`, `StoriesPage` from `user-interface`; `setQueueBackend` from `task-queue`; `RandomUuidGenerator` from `utils`.
   - Instantiate `MobileQueueBackend`, call `setQueueBackend(...)`.
   - Render `HashRouter` with the same provider nesting as `dev-frontend` (`UuidGeneratorProvider` → `PlatformProviderMobile` → `ApiContextProvider` → `AppContextProvider` → `ToastContextProvider` → `AssetDatabaseProvider` → `ImportContextProvider` → `GalleryContextProvider` → `DeleteConfirmationContextProvider` → `SearchContextProvider` → `GalleryLayoutContextProvider` → `Main isMobile={true} initialTheme="system"`).
   - Pass a placeholder `restApiUrl` (e.g. `"http://localhost:3001"`) to `AssetDatabaseProvider`.
   - Keep the `/stories` route for parity.
   - Set `isMobile={true}`.

7. Update `apps/ios-frontend/src/index.tsx` to import the UI styles: add `import '@fortawesome/fontawesome-free/css/all.css'` and `import './tailwind.css'`.

8. Update `apps/ios-frontend/jest.config.js` `moduleNameMapper` to map workspace packages to their TypeScript sources (add `^task-queue$`, `^user-interface$`, `^utils$` as needed). Confirm `testEnvironment: 'jsdom'`.

9. Rebuild and re-sync: run `vite build` then `cap sync ios` so the real UI bundle is copied into the native project (macOS/CocoaPods caveat applies; assert conditionally when `ios/` exists).

10. If the About route cannot be reached because an earlier screen hard-requires a database/native call, add the minimal stub return needed to `platform-provider-mobile.tsx` (do not modify `user-interface` beyond what is required to reach `/about`).

## Unit Tests

Create/update in `apps/ios-frontend/src/test/`:

- `mobile-queue-backend.test.ts`: verify `MobileQueueBackend.addTask` returns the supplied `taskId`, returns a non-empty string when none is supplied, that the `on*` registration methods return callable no-op unsubscribe functions, and that `cancelTasks`/`shutdown` do not throw.
- `platform-provider-mobile.test.tsx`: render a child inside `PlatformProviderMobile` and assert it renders; assert the in-memory `config` round-trips a set/get value.
- `about-navigation.test.tsx`: render `<App />`, set `window.location.hash = '#/about'`, and assert the About page heading `About Photosphere` (from `packages/user-interface/src/pages/about.tsx`) appears. Automated stand-in for "switch to the About page on device".

The Phase 1 `app.test.tsx` from Step 2 may be removed or updated since `app.tsx` no longer renders "Hello world".

## Smoke Test

Update `apps/ios-frontend/smoke-tests.sh` for Phase 2:

- Keep compile + bundle + `cap sync ios` assertions (conditional asset-copy assertion when `ios/` exists).
- Replace the "Hello world" bundle-content assertion with: assert the built JS bundle references the About page (grep for `About Photosphere`).

## Verify

- `bun run compile` (root) succeeds.
- `bun run test` (root unit tests) passes, including the new tests in `ios-frontend`.
- `bun run test:ios` passes (compile + Vite build + `cap sync ios` + the `About Photosphere` bundle assertion).
- `bun run --filter=ios-frontend bundle` produces a `dist/` with `index.html` and JS assets.
- `apps/ios-frontend/ios/App/` scaffolding exists (note macOS-only `pod install` caveat).
- `bun run test:all` confirms no regressions in existing packages.

Run all tests and confirm they pass before marking this step complete.

## Summary

_To be completed when this step is implemented._
