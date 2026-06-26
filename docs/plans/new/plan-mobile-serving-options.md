# Mobile File Serving: Options

## Overview
The Android and iOS frontends (`apps/android-frontend`, `apps/ios-frontend`) currently wrap the real Photosphere UI in Capacitor with `PlatformProviderMobile` returning empty defaults: there is no way to serve asset bytes to the WebView. On desktop, Electron serves assets via a Node express server on localhost (`apps/desktop/src/rest-api-worker.ts` running `createAssetServer`, with the renderer loading `http://localhost/asset?id=...`). That server cannot run on mobile because there is no Node process. This document captures the options for serving local asset bytes to the mobile WebView and their trade-offs. It does not pick a path. It exists so we can choose an approach and then write a detailed implementation plan for that choice.

How files are stored locally is a separate decision, covered in `plan-mobile-storage-options.md`. The serving options below read bytes from whatever storage backend is chosen there. The one exception is `convertFileSrc`, which needs real file paths and so only works with a native file-backed storage backend.

Hard rule: no third-party Capacitor plugins. Every option below relies only on our own native code (exposed to JS through our own Capacitor plugin), Capacitor core, or standard web APIs. Options that would need a third-party plugin are excluded.

## Issues
<!-- Populated later by plan:check -->

## Serving Local Files to the WebView

### Native option: custom URL-scheme handler (`photosphere://asset?id=...`)
Our own native code (WKURLSchemeHandler on iOS, `shouldInterceptRequest` on Android) answers asset URLs straight from storage.
- Pro: streams bytes straight from storage, supports on-the-fly decryption, no temp files.
- Pro: behaves like the existing REST API; reads from any storage backend.
- Pro: our own native code, not a third-party plugin.
- Con: two native implementations to write and maintain.

### Native option: our own local HTTP server (Swift / Kotlin)
A small HTTP server we write, running on localhost on the device, serving assets to the WebView.
- Pro: closest behavioral match to Electron (range requests, dynamic decrypt).
- Pro: the renderer code barely changes (still fetches a localhost URL).
- Pro: our own native code, not a third-party plugin.
- Con: writing our own HTTP server is real work, on two platforms.
- Con: the route logic is reimplemented natively (the Node express code cannot be reused).

### Capacitor-core option: `Capacitor.convertFileSrc(path)`
- Pro: simple. The WebView loads the URL directly in `<img>` / `<video>` and handles video range requests.
- Pro: part of Capacitor core, not a separate third-party plugin (still Capacitor-dependent).
- Con: the file must exist on disk as a real path, so it only works with a native file-backed storage backend, not OPFS / IndexedDB.
- Con: encrypted assets must be decrypted to a temp file first.

### Web option: blob / object URLs (`URL.createObjectURL`)
- Pro: no plugin, no native code, pure web. Reads bytes from any storage backend.
- Pro: works offline.
- Con: weaker for large galleries (memory) and video range / streaming.
- Con: object-URL lifetime and revocation must be managed.

### Remote option: server serving (`restApiUrl` over the network)
- Pro: reuses all existing REST code unchanged. No native code, no plugin.
- Con: requires connectivity. Not local / offline.
- Con: bandwidth cost for every thumbnail / asset.

## Steps
Pending a chosen serving mechanism. Once selected, this section will be filled with concrete file-level implementation steps (native handler / server if applicable, wiring in `PlatformProviderMobile`, and asset-URL construction in the frontend).

## Unit Tests
Pending a chosen serving mechanism.

## Smoke Tests
Pending a chosen serving mechanism.

## Verify
Pending a chosen serving mechanism. Will include running all unit tests and all smoke tests plus mobile build / compile checks for the selected path.

## Notes
- Storage is decided separately (`plan-mobile-storage-options.md`). All serving options here read bytes from any storage backend, except `convertFileSrc`, which needs real file paths and so only works with a native file-backed storage backend.
- Key code references:
  - `apps/desktop/src/rest-api-worker.ts`: the Electron localhost REST serving model to replace.
  - `packages/user-interface/src/context/asset-database-source.tsx`: how the frontend builds `assetUrl` (the URL the WebView loads for each asset).
  - `apps/android-frontend/src/lib/platform-provider-mobile.tsx`: current stubbed platform provider.
</content>
