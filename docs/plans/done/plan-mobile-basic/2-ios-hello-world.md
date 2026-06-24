# Step 2 — iOS "Hello world" frontend + native project

Phase 1 for iOS. Stand up the `apps/ios-frontend` workspace package rendering only "Hello world", generate the iOS native project (with the macOS/CocoaPods caveat), and wire root scripts. Includes the package README and the Phase 1 render test + build-based smoke test.

## Scope

Source: `plan-mobile-basic.md` Phase 1 "iOS frontend package" (steps 12–15) plus the iOS parts of "Root wiring" (step 16). The iOS frontend mirrors the Android frontend produced in Step 1; only the native project and the `@capacitor/ios` dependency differ.

## Work

### Package scaffolding

1. Create the workspace package directory `apps/ios-frontend/`, a self-contained Capacitor package holding the iOS React frontend and the generated iOS native project.

2. Create `apps/ios-frontend/package.json`, identical in shape to `apps/android-frontend/package.json` but:
   - `"name": "ios-frontend"`.
   - `dependencies` use `@capacitor/ios@^5.7.4` instead of `@capacitor/android`.
   - Scripts use the iOS variants: `"sync": "vite build && cap sync ios"`, `"open:ios": "cap open ios"`, `"run:ios": "cap run ios"`.
   - Same `^5.x` Capacitor pin.

3. Create `apps/ios-frontend/capacitor.config.ts`, `apps/ios-frontend/index.html`, `apps/ios-frontend/vite.config.ts`, `apps/ios-frontend/tsconfig.json`, `apps/ios-frontend/jest.config.js`, `apps/ios-frontend/src/index.tsx`, `apps/ios-frontend/src/app.tsx`, `apps/ios-frontend/.gitignore`, and `apps/ios-frontend/README.md` — same content as the Android frontend equivalents from Step 1. The `app.tsx` again renders only `<h1>Hello world</h1>` with a `//` comment block above `App`. Add `ios/App/Pods/` to the `.gitignore`.

### Native project

4. Generate the iOS native project: from `apps/ios-frontend` run `vite build` then `npx cap add ios`. This creates `apps/ios-frontend/ios/`. Note: the `pod install` step run by `cap add ios` requires CocoaPods/macOS; on the Linux dev box it may warn or partially complete. If it fails, still commit the generated `ios/App` scaffolding and document that `pod install` / `cap sync ios` must be completed on macOS.

### Root wiring (iOS parts)

5. Add root convenience scripts to the top-level `package.json` `scripts`:
   - `"sync:ios": "bun run --filter=ios-frontend sync"`.
   - `"test:ios": "cd ./apps/ios-frontend && ./smoke-tests.sh"` (smoke runner, see below).
   - Do not wire mobile into `test:all` yet.
   - Confirm the root `.gitignore` does not exclude the new `apps/ios-frontend` sources.

## Unit Tests

Create `apps/ios-frontend/src/test/app.test.tsx` (Phase 1): render `<App />` with `@testing-library/react` and assert the text `Hello world` is in the document. Automated stand-in for "see Hello world on device".

## Smoke Test

Add `apps/ios-frontend/smoke-tests.sh` (invoked via `bun run test:ios`, never called directly per repo rules). Build/bundle based, not device based:

- Run `compile` (tsc) and assert exit 0.
- Run `bundle` (Vite build) and assert `dist/index.html` and a hashed JS bundle exist.
- Assert the built JS bundle contains the string `Hello world`.
- Run `cap sync ios` and assert exit 0; only conditionally assert web assets were copied into the `ios/App` public dir when `ios/` generated successfully (macOS-only caveat).
- Document inside the script (comment) that on-device launch (`cap run ios`) requires Xcode and is performed outside automated CI.

## Verify

- `bun install` from repo root succeeds and links the new `ios-frontend` workspace.
- `bun run compile` (root) succeeds with the new package included.
- `bun run --filter=ios-frontend bundle` produces a `dist/` with `index.html` and JS assets.
- `apps/ios-frontend/ios/App/` scaffolding exists (note macOS-only `pod install` caveat if it could not complete on Linux).
- `bun run test:ios` passes.

Run all tests and confirm they pass before marking this step complete.

## Summary

Implemented the iOS "Hello world" frontend package and generated its native project, mirroring the Android package from Step 1.

### Files created (`apps/ios-frontend/`)
- `package.json` — `ios-frontend` workspace package; same shape as `android-frontend` but uses `@capacitor/ios@^5.7.4` and iOS script variants (`sync: vite build && cap sync ios`, `open:ios`, `run:ios`). Capacitor pinned to `^5.x`.
- `capacitor.config.ts`, `index.html`, `vite.config.ts`, `tsconfig.json`, `jest.config.js` — identical content to the Android equivalents.
- `src/index.tsx`, `src/app.tsx` (`App` renders `<h1>Hello world</h1>`), `src/test/app.test.tsx`, `src/test/setup.ts`.
- `.gitignore` — same as Android plus iOS entries (`ios/App/Pods/`, `ios/App/App/public/`, generated config, `DerivedData/`, `ios/build/`).
- `README.md` — iOS pre-reqs (Mac + Xcode + CocoaPods) and run commands, with the macOS-only `pod install` note.
- `smoke-tests.sh` — compile + bundle + bundle-contains-"Hello world" + `cap sync ios`; the web-asset copy assertion is conditional on `ios/App` existing.

### Native project
- Generated `apps/ios-frontend/ios/` via `bunx cap add ios`. On this Linux box the Xcode project scaffolding and the web-asset copy (`ios/App/App/public`) were created; `pod install` and `xcodebuild clean` were skipped (CocoaPods/Xcode not installed) with warnings, exactly as the plan anticipated. Those steps must be completed on macOS before a device build.

### Root wiring (`package.json`)
- Added `"sync:ios": "bun run --filter=ios-frontend sync"` and `"test:ios": "cd ./apps/ios-frontend && ./smoke-tests.sh"`. Mobile still not added to `test:all`.

### Decisions / divergences
- The iOS native project generated further than expected on Linux: the web-asset copy into `ios/App/App/public` did complete, so the smoke test's conditional asset assertion actually runs and passes (it only skips if `ios/App` is absent).
- Same Testing-Library version pins and `bunx cap` (not npx) choices as Step 1.

### Verification
- `bun install`, root `bun run compile` (ios-frontend exits 0), `bun run --filter=ios-frontend test` (1 passed), and `bun run test:ios` (compile + bundle + sync, with asset copy asserted) all pass. Generated build outputs are gitignored; 30 source files tracked.

### Out of scope / deferred
- `pod install` / final `cap sync ios` and on-device launch (`cap run ios`) require macOS + Xcode + CocoaPods and are not run in CI.
