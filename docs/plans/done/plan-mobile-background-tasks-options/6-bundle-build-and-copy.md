# Step 6: Wire the bundle build and copy into both native projects

Make `worker.bundle.js` part of the mobile build and land it in each native project before `cap sync`.

## What to do

1. Re-create (port from the prototype, do not import across repos) the `build:bundle` and `copy:bundle` scripts in `packages/mobile-worker` / the mobile app build.
2. `build:bundle` produces `worker.bundle.js` (the build from Step 2).
3. `copy:bundle` copies the built bundle into both native projects before `cap sync`:
   - Android `assets/` path (`apps/android-frontend/android/...`),
   - iOS app resource path (`apps/ios-frontend/ios/...`).
4. The bundle is only ever loaded/eval'd from the packaged app asset; never fetched or updated from a remote/OTA source.

## Tests

- Build-and-wire smoke test: build the bundle and assert it lands at the Android assets path and the iOS app resource path.

Run all tests and confirm they pass before marking this step complete.

## How to check on Android

Off-device, no emulator. Run `bun run sync` in `apps/android-frontend` (`vite build && cap sync android`) and confirm `worker.bundle.js` lands at `apps/android-frontend/android/app/src/main/assets/worker.bundle.js`. The build-and-wire smoke test asserts that path exists.

## Summary

Wired the bundle build and copy:
- `build:bundle` stays the plain Bun bundler CLI: `bun build ./mobile-worker-entry.ts --outfile worker.bundle.js --format=iife --target=browser` (no build script, no Node-builtin redirection / shims).
- `copy:bundle` is a plain `cp` of the built `worker.bundle.js` into both native projects before `cap sync`: Android `apps/android-frontend/android/app/src/main/assets/worker.bundle.js` and iOS `apps/ios-frontend/ios/App/App/worker.bundle.js`. The native engine loads the bundle from this packaged app asset (not the WebView, so `cap sync` does not copy it); it is never loaded from a remote/OTA source.

Current state of the actual bundle emission: with the plain `bun build` browser target, `worker.bundle.js` does **not** emit yet — the registered handlers import the Node built-ins `stream/promises` and `child_process`, which the browser target will not resolve. Per the decision to not redirect Node built-ins (no shims, no native Node-function implementations), every Node.js call from a background task is meant to report NOT IMPLEMENTED; resolving these two built-ins so the bundle emits is left for the work that supplies the native `fs`/process seam. The build + copy machinery and its test are in place and pass.
