# Mobile Local Storage: Options

## Overview
The Android and iOS frontends (`apps/android-frontend`, `apps/ios-frontend`) currently wrap the real Photosphere UI in Capacitor with `PlatformProviderMobile` returning empty defaults: nothing is wired to local storage. The device has a real file system, but the WebView cannot reach it directly (no `fs`), so we need to decide how the app stores files. This document captures the options and their trade-offs. It does not pick a path. It exists so we can choose an approach and then write a detailed implementation plan for that choice.

Serving asset bytes to the WebView is a separate decision, covered in `plan-mobile-serving-options.md`.

This plan is related to `plan-mobile-background-tasks-options.md`: the on-device task options there read and write through whichever storage backend this plan selects.

Hard rule: no third-party Capacitor plugins. Every option below relies only on our own native code (exposed to JS through our own Capacitor plugin) or standard web APIs. Options that would need a third-party plugin are excluded.

## Issues
<!-- Populated later by plan:check -->

## Local File System Representation

`IStorage` (`packages/storage/src/lib/storage.ts`) currently returns Node `Buffer` and `Readable`, so any mobile implementation needs those swapped for `Uint8Array` / web streams or a shim.

Reaching the device's real, OS-visible file system from the WebView requires a native bridge. The native options below hit the real file system; the web-storage options are sandboxed (private to the app, invisible to the OS file manager / gallery).

### Native option: custom storage bridge (our own Swift / Kotlin)
A bridge we write: our own Capacitor plugin exposing `read` / `write` / `list` / `delete` / `stat` to JS, with `IStorage` implemented in TS on top of it (mirroring `file-storage.ts`). Native side uses the platform file APIs (`FileManager` on iOS, `java.io.File` / SAF on Android) against the app sandbox directories.
- Pro: full control over behaviour, paths, streaming, and range reads. Our own code, no third-party plugin.
- Pro: real path-based native files, the direct analog to Electron `fs`.
- Pro: can stream bytes and support partial reads, which helps video serving.
- Pro: extensible later to shared storage / camera roll (see the photo-library option below).
- Con: two native codebases (Swift and Kotlin) to write and maintain.

### Native option: app-sandbox-only storage bridge (our own Swift / Kotlin)
The same idea scoped narrowly to the app's own Documents / Application Support sandbox: a thin read / write / list bridge, no permissions prompts, no shared-storage handling.
- Pro: smallest native surface to write and maintain.
- Pro: no runtime permissions needed (app-private directories).
- Pro: real native files, survives restarts, backed up by the OS as app data.
- Con: files live only inside the app sandbox, not visible to other apps or the gallery.
- Con: still two native codebases, however small.

### Native option: storage bridge with shared media / photo-library access (our own Swift / Kotlin)
The custom storage bridge extended to reach the user's existing photos: native media APIs (`PHPhotoLibrary` on iOS, `MediaStore` / SAF on Android) bridged to JS, so the app can import from and write to the camera roll and shared storage.
- Pro: can read the user's existing photo library and write into shared storage.
- Pro: real native files, OS-visible.
- Con: most native code and the most platform-specific behaviour to maintain.
- Con: requires runtime permission prompts and handling of permission denial.
- Con: media APIs are not a plain file system; mapping them onto `IStorage` is awkward.

### Web-storage option: OPFS (Origin Private File System)
- Pro: browser-standard, no plugin, no native code.
- Pro: fast, path-like API, accessible from Web Workers.
- Pro: large capacity.
- Con: sandboxed web storage, not the real OS file system. Invisible to other apps / gallery.
- Con: WebView version support varies, weaker on older Android WebViews.

### Web-storage option: IndexedDB
- Pro: browser-standard, no plugin, broad support.
- Pro: large capacity, good for blobs.
- Con: sandboxed web storage, not a real filesystem. Directory / path semantics must be emulated.
- Con: clunky for streaming large video.

### Web-storage option: localStorage / browser local store
- Pro: trivial API, no plugin, no native code.
- Con: ~5-10 MB cap, synchronous, strings only. Unusable for photos / video.

## Steps
Pending a chosen storage backend. Once selected, this section will be filled with concrete file-level implementation steps (new `IStorage` implementation, native bridge if applicable, and wiring in `PlatformProviderMobile`).

## Unit Tests
Pending a chosen storage backend.

## Smoke Tests
Pending a chosen storage backend.

## Verify
Pending a chosen storage backend. Will include running all unit tests and all smoke tests plus mobile build / compile checks for the selected path.

## Notes
- Serving is decided separately (`plan-mobile-serving-options.md`). The only place the two choices interact: `convertFileSrc` serving needs real file paths, so it cannot pair with the sandboxed web-storage backends. Every other serving option reads bytes from any storage backend.
- Related to `plan-mobile-background-tasks-options.md`. The on-device task options there read and write through the storage backend chosen here.
- Key code references:
  - `apps/android-frontend/src/lib/platform-provider-mobile.tsx`: current stubbed platform provider.
  - `packages/storage/src/lib/file-storage.ts`: Node `fs` implementation of `IStorage` to mirror.
  - `packages/storage/src/lib/storage.ts`: the `IStorage` interface a mobile backend implements.
</content>
