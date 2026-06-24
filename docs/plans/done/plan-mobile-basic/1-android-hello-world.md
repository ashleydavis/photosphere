# Step 1 — Android "Hello world" frontend + native project

Phase 1 for Android. Stand up the `apps/android-frontend` workspace package rendering only "Hello world", generate the Android native project, and wire root scripts. Includes the package README (the plan's only documentation deliverable) and the Phase 1 render test + build-based smoke test.

## Scope

Source: `plan-mobile-basic.md` Phase 1 "Android frontend package" (steps 1–11a) plus the Android parts of "Root wiring" (step 16).

## Work

### Package scaffolding

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
   - `appId`: `"au.com.codecapers.photosphere"` (placeholder; see plan Notes).
   - `appName`: `"Photosphere"`.
   - `webDir`: `"dist"` (Vite build output copied into the native project by `cap sync`).
   - `bundledWebRuntime: false`, empty `plugins: {}`.

4. Create `apps/android-frontend/index.html` modeled on `apps/dev-frontend/index.html`: `<div id="app"></div>` root, mobile viewport meta `viewport-fit=cover, width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no`, `<script type="module" src="./src/index.tsx"></script>`, title "Photosphere".

5. Create `apps/android-frontend/vite.config.ts` modeled on `apps/desktop-frontend/vite.config.ts`: `plugins: [react()]`, `base: './'` (Capacitor serves from a non-http origin so relative asset paths are required), `build: { outDir: 'dist', emptyOutDir: true, sourcemap: true }`.

6. Create `apps/android-frontend/tsconfig.json` modeled on `apps/desktop-frontend/tsconfig.json` (`composite: true`, `jsx: "react-jsx"`, `module: "ESNext"`, `moduleResolution: "bundler"`, `rootDir: "./src"`, `noEmit: true`, `strict: true`, `skipLibCheck: true`, `lib: ["ES2020","DOM","DOM.Iterable"]`).

7. Create `apps/android-frontend/jest.config.js` modeled on `apps/desktop-frontend/jest.config.js`, but `testEnvironment: 'jsdom'` (the Hello-world render test needs a DOM). Keep `modulePathIgnorePatterns` for `dist`/`build`. No `moduleNameMapper` needed in Phase 1.

8. Create `apps/android-frontend/src/index.tsx` modeled on `apps/dev-frontend/src/index.tsx`: import React and `createRoot`, import `{ App } from "./app"`, get `document.getElementById('app')`, throw if missing, `createRoot(container).render(<App />)`. No fontawesome/tailwind imports in Phase 1.

9. Create `apps/android-frontend/src/app.tsx` with a minimal exported named function `App` returning `<h1>Hello world</h1>` inside a root `<div>`. Add a `//` comment block above `App` per code style rules.

### Native project + ignore + README

10. Generate the Android native project: run `bun install` from repo root first (so `@capacitor/*` and the CLI resolve through the workspace), run `vite build` in `apps/android-frontend` so `dist/` exists, then from `apps/android-frontend` run `npx cap add android`. This creates `apps/android-frontend/android/`.

11. Add `apps/android-frontend/.gitignore` (modeled on `capacitor-basic-example/.gitignore` plus Capacitor's generated ignores) to exclude `node_modules/`, `dist/`, `.gradle/`, build outputs, `*.map`, `.DS_Store`. Keep the native project sources (`android/`) tracked.

11a. Add `apps/android-frontend/README.md` modeled on `/home/ash/projects/photosphere/capacitor-example/README.md`: pre-reqs (Node/Bun, Android Studio, Xcode + CocoaPods for iOS), setup, and the Android/iOS run commands adapted to this package's `bun run` scripts. This is the only documentation produced by the plan for this package.

### Root wiring (Android parts)

12. Add root convenience script to the top-level `package.json` `scripts`:
    - `"sync:android": "bun run --filter=android-frontend sync"`.
    - `"test:android": "cd ./apps/android-frontend && ./smoke-tests.sh"` (smoke runner, see below).
    - Do not wire mobile into `test:all` yet (no device automation available in CI).
    - Confirm the root `.gitignore` does not exclude the new `apps/android-frontend` sources (the stale `apps/mobile/frontend/build` entry does not match this layout and can be left as-is).

## Unit Tests

Create `apps/android-frontend/src/test/app.test.tsx` (Phase 1): render `<App />` with `@testing-library/react` and assert the text `Hello world` is in the document. Automated stand-in for "see Hello world on device".

## Smoke Test

Add `apps/android-frontend/smoke-tests.sh` (invoked via `bun run test:android`, never called directly per repo rules). No emulator exists in this environment, so the smoke test is build/bundle based, not device based:

- Run `compile` (tsc) and assert exit 0.
- Run `bundle` (Vite build) and assert `dist/index.html` and a hashed JS bundle exist.
- Assert the built JS bundle contains the string `Hello world`.
- Run `cap sync android` and assert exit 0 and that web assets were copied into `android/app/src/main/assets/public/`.
- Document inside the script (comment) that on-device launch (`cap run android`) requires Android Studio and is performed outside automated CI.

## Verify

- `bun install` from repo root succeeds and links the new `android-frontend` workspace.
- `bun run compile` (root) succeeds with the new package included.
- `bun run --filter=android-frontend bundle` produces a `dist/` with `index.html` and JS assets.
- `apps/android-frontend/android/` exists and `cap sync android` reports the platform updated.
- `bun run test:android` passes.

Run all tests and confirm they pass before marking this step complete.

## Summary

Implemented the Android "Hello world" frontend package and generated its native project.

### Files created (`apps/android-frontend/`)
- `package.json` — `android-frontend` workspace package, scripts (`compile`, `bundle`, `test`, `clean`, `sync`, `open:android`, `run:android`), React 18 + `@capacitor/{core,android}@^5.7.4` deps, `@capacitor/cli@^5.7.4` plus Vite/Jest/Testing-Library dev deps. All `@capacitor/*` pinned to `^5.x`.
- `capacitor.config.ts` — typed `CapacitorConfig`, `appId: au.com.codecapers.photosphere`, `appName: Photosphere`, `webDir: dist`, `bundledWebRuntime: false`, empty `plugins`.
- `index.html` — `#app` root, mobile viewport meta, module script to `./src/index.tsx`.
- `vite.config.ts` — `react()`, `base: './'`, `build: { outDir: 'dist', emptyOutDir: true, sourcemap: true }`.
- `tsconfig.json` — modeled on desktop-frontend (composite, `react-jsx`, ESNext/bundler, strict, skipLibCheck, noEmit).
- `jest.config.js` — `ts-jest`, `testEnvironment: 'jsdom'`, `setupFilesAfterEnv` for jest-dom, ignores `dist`/`build`.
- `src/index.tsx`, `src/app.tsx` (`App` renders `<h1>Hello world</h1>`).
- `src/test/app.test.tsx` (render assertion) and `src/test/setup.ts` (imports `@testing-library/jest-dom`).
- `.gitignore`, `README.md`, `smoke-tests.sh` (compile + bundle + bundle-contains-"Hello world" + `cap sync android` asset-copy check).

### Native project
- Generated `apps/android-frontend/android/` via `bunx cap add android` (no Gradle/Android SDK needed for generation). Native sources tracked; generated build outputs and copied web assets ignored via `.gitignore`.

### Root wiring (`package.json`)
- Added `"sync:android": "bun run --filter=android-frontend sync"` and `"test:android": "cd ./apps/android-frontend && ./smoke-tests.sh"`. Mobile intentionally not added to `test:all`.

### Decisions / divergences
- Added a `src/test/setup.ts` + `setupFilesAfterEnv` (not spelled out in the step) so `@testing-library/jest-dom` matchers like `toBeInTheDocument` work.
- Pinned `@testing-library/react@^14.2.1` and `@testing-library/jest-dom@^6.4.2` (step left versions unspecified).
- Smoke script uses `bunx cap` (repo uses Bun, not npx).
- `bundledWebRuntime: false` is kept per the plan even though Capacitor 5 prints a harmless deprecation warning.

### Verification
- `bun install`, root `bun run compile` (all 25 packages exit 0), `bun run --filter=android-frontend test` (1 passed), and `bun run test:android` (compile + bundle + sync) all pass. Full root `bun run test` suite passes with no regressions.

### Out of scope / deferred
- On-device launch (`cap run android`) requires Android Studio and is not run in CI.
