# Step 7: Wire the bundle build and copy into both native projects

Make `worker.bundle.js` part of the mobile build and land it in each native project before `cap sync`.

## What to do

1. Re-create (port from the prototype, do not import across repos) the `build:bundle` and `copy:bundle` scripts in `packages/mobile-worker` / the mobile app build.
2. `build:bundle` produces `worker.bundle.js` (the build from Step 3).
3. `copy:bundle` copies the built bundle into both native projects before `cap sync`:
   - Android `assets/` path (`apps/android-frontend/android/...`),
   - iOS app resource path (`apps/ios-frontend/ios/...`).
4. The bundle is only ever loaded/eval'd from the packaged app asset; never fetched or updated from a remote/OTA source.

## Tests

- Build-and-wire smoke test: build the bundle and assert it lands at the Android assets path and the iOS app resource path.

Run all tests and confirm they pass before marking this step complete.

## Summary

_To be completed when this step is implemented._
