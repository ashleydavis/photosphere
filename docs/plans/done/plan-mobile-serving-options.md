# Mobile File Serving: Asset Server as a Background Task

## Overview
The Android and iOS frontends wrap the real Photosphere UI in Capacitor, but there is no way to serve local asset bytes to the WebView, so the gallery cannot display thumbnails, display images, or video. On desktop this is solved by the asset server: `createAssetServer` (in `packages/rest-api`) runs an express HTTP server in a dedicated Electron utility process (`apps/desktop/src/rest-api-worker.ts`, spawned by `initRestApi` in `apps/desktop/src/main.ts`), and the renderer loads `http://localhost:<port>/asset?id=...&type=...&db=...`. The renderer builds those URLs in `packages/user-interface/src/context/asset-database-source.tsx` (`assetUrl` and `loadAsset`) from a `restApiUrl` prop.

The plan is to reuse that exact serving model on mobile, in two steps:

1. Refactor the asset server so it runs as an ongoing (long-running) background task instead of a bespoke Electron utility process, reusing the existing `task-queue` infrastructure.
2. Run that same asset-server task on mobile inside the embedded JS engine, serving over a real localhost HTTP socket exactly like Electron. The WebView loads `http://localhost:<port>/asset?...` URLs with no frontend branching.

This works on mobile because background tasks already run there (in the embedded JS engine, see `docs/background-tasks.md`). To let the engine run the real express server, we implement the functions the asset server needs. Everything is implemented in TypeScript except the one thing the engine genuinely cannot do in JS: open and accept connections on a TCP socket. That irreducible piece is a small set of native host functions (Swift on iOS, Kotlin on Android); the `http` and `net` layers and everything above them are TypeScript. Every function added is unit tested.

## Issues
- The embedded engine has no TCP sockets. `packages/mobile-worker/src/shims/node-http.ts` and `node-net.ts` are placeholders (one throws NOT IMPLEMENTED, the other is a type-only stub). We replace them with real implementations backed by native TCP primitives.
- The host bridge today is synchronous call-and-return plus outbound streaming (`sendMessage`) and native-to-frontend events. A listening socket needs the opposite direction too: native must push inbound events (connection accepted, data received, connection closed) into the engine to drive the JS server. Adding that native-to-engine inbound push is the core new capability and the main risk in this plan.
- WebView reachability: the WebView origin (capacitor/https localhost) loading `http://localhost:<port>` may be treated as mixed content or cross-origin. The asset server already sends permissive CORS headers; loopback cleartext access may need a small Capacitor config allowance. This is the same URL model as Electron.
- Express has transitive Node dependencies (for example `events`, `buffer`, `querystring`, `url`) that must resolve in the engine. The bundle build (`packages/mobile-worker/build-bundle.ts`) already aliases several Node modules to shims; any remaining ones get the same minimal-shim treatment.
- Serving real bytes depends on the storage/fs layer (decided in `plan-mobile-storage-options.md`). The HTTP-server functions and the asset-server task are implementable and unit-testable independently using seeded in-memory storage, so this plan does not block on storage.

## Approach

### Part A: Asset server as a long-running background task (Electron and CLI first)
Split the transport-agnostic serving logic out of the express wiring, then run it as a task. On Node (Electron, CLI) the task still stands up the express HTTP server exactly as today, so behaviour and the localhost URL are unchanged. This part is fully testable on Node before any mobile work.

### Part B: Run the same task on mobile over a real localhost socket
Implement the functions the express asset server needs so it runs unchanged in the engine: native TCP primitives, a TypeScript `net` layer over them, a TypeScript `http` layer over `net`. Start the task in the engine, and point the mobile `restApiUrl` at the bound localhost URL.

## Steps

### Part A
1. In `packages/rest-api/src/lib/asset-server.ts`, extract the transport-agnostic core: move the storage cache, `getAssetStorage`, `loadAssetStream`, the asset write helper, and the apply-ops helper into a `createAssetServerCore(options)` that returns named methods (`serveAsset(id, type, db)`, `writeAsset(...)`, `applyDatabaseOps(...)`). Have the existing express routes in `createAssetServer` call the core so HTTP behaviour is byte-for-byte unchanged.
2. Add a long-running `asset-server` task handler under `packages/node-api/src/lib/asset-server.worker.ts`. It builds the core, calls `createAssetServer` to bind an HTTP port, reports the chosen port back with a `context.sendMessage` of type `asset-server-ready`, and stays alive until cancelled.
3. Register `"asset-server"` in `packages/api/src/lib/task-handlers.ts` and export its types.
4. Switch Electron off the bespoke utility process: in `apps/desktop/src/main.ts`, replace `initRestApi` and the `utilityProcess.fork` of `rest-api-worker.ts` with starting the `asset-server` task on its own queue at startup, awaiting the `asset-server-ready` port message, and building `restApiUrl` from it. Remove `apps/desktop/src/rest-api-worker.ts` and its bundle entry once nothing references it.

### Part B
5. Add native TCP host functions (Swift on iOS, Kotlin on Android), the only native code in this plan:
   - `tcpListen(host, port)`: bind a loopback TCP listener and return its listener id and the actual bound port (port 0 means OS-assigned).
   - `tcpWrite(connectionId, base64)`: write bytes to a connection.
   - `tcpClose(connectionId)`: close one connection.
   - `tcpStopListening(listenerId)`: close the listener.
   - Inbound push: extend the `JsEngine` bridge so native delivers `connection` (new connectionId), `data` (connectionId plus base64), and `close` (connectionId) events into the engine, driving the JS server. Add the new function names to `EXPECTED_HOST_FUNCTIONS` in `packages/mobile-worker/src/lib/host-functions.ts`.
6. Replace `packages/mobile-worker/src/shims/node-net.ts` with a real implementation: a `Server` (listen, close, emits `connection` with a `Socket`) and a `Socket` (emits `data` and `end`, supports `write` and `end`) built on the TCP host functions and the inbound event push.
7. Replace `packages/mobile-worker/src/shims/node-http.ts` with a real implementation: `createServer(requestListener)` returns a server over `net` that parses each request into an `IncomingMessage` (method, url, headers, body) and provides a `ServerResponse` (`statusCode`, `setHeader`, `writeHead`, `write`, `end`) serialised back to the socket. Minimal HTTP/1.1 with Content-Length framing, only what express and the asset routes use.
8. Start the `asset-server` task from `packages/mobile-frontend` when a database is in context, on its own queue so it does not starve the engine pool, and read the bound port from the `asset-server-ready` message.
9. In `packages/mobile-frontend/src/lib/platform-provider-mobile.tsx`, set `restApiUrl` to `http://localhost:<port>` so `assetUrl` and `loadAsset` build the same URLs as Electron with no frontend branching.

## Unit Tests
- `createAssetServerCore`: `serveAsset` returns the expected bytes for `thumb`, `display`, and `asset` from a seeded storage; missing `id`/`type`/`db` and missing-asset cases error as expected. (`packages/rest-api` test.)
- `asset-server` task handler: on Node, starting the task emits an `asset-server-ready` message with a port and the server answers `GET /asset`; cancelling the task stops the server.
- `net` shim (with a mock host bridge): `listen` binds via `tcpListen`; a simulated inbound `connection` emits a `Socket`; inbound `data` emits `data`; `write` calls `tcpWrite`; `close` calls `tcpClose`/`tcpStopListening`.
- `http` shim: feeding raw HTTP request bytes through a mock socket yields the expected parsed `IncomingMessage` (method, url, headers, body), and a `ServerResponse` produces the expected raw response bytes (status line, headers, Content-Length body).
- Asset server over the shimmed `http` plus seeded in-memory storage: `GET /asset` returns the bytes and the `POST` routes succeed (reuses the Part A core, runs in TS with the mock host).
- Native: minimal XCTest (iOS) and JUnit/instrumented (Android) for a loopback echo round-trip: `tcpListen`, accept a client connection, receive bytes, `tcpWrite` them back, then close.

## Smoke Tests
- Electron: the existing asset-display smoke tests pass unchanged against the task-based server (regression that the refactor did not change behaviour). Run via `bun run test:electron`.
- Mobile (iOS and Android): extend the existing mobile smoke-test jobs to open a seeded database and assert gallery thumbnails load over `http://localhost:<port>`, proving the engine binds the socket and serves bytes.

## Verify
- `bun run compile`
- `bun run test:all`
- `bun run test:electron`
- The Android and iOS mobile smoke-test jobs.

## Notes
- Storage is decided separately in `plan-mobile-storage-options.md`. The asset-server core reads bytes from whatever storage backend is chosen there.
- Native code is kept to the smallest possible surface: only the TCP socket primitives, which cannot be done in JS in the engine. The `net` layer, the `http` layer, express, and the asset server are all TypeScript and shared with desktop.
- Key code references:
  - `packages/rest-api/src/lib/asset-server.ts`: the asset server to refactor into a reusable core plus express wiring.
  - `apps/desktop/src/rest-api-worker.ts` and `initRestApi` in `apps/desktop/src/main.ts`: the bespoke utility process to replace with the task.
  - `packages/mobile-worker/src/shims/node-http.ts` and `node-net.ts`: the placeholders to replace with real implementations.
  - `packages/mobile-worker/src/lib/host-functions.ts`: where the new TCP host-function names are registered.
  - `packages/mobile-worker/build-bundle.ts`: where Node module imports are aliased to shims.
  - `packages/user-interface/src/context/asset-database-source.tsx`: `assetUrl` and `loadAsset`, which build URLs from `restApiUrl` and stay unchanged.
  - `packages/mobile-frontend/src/lib/platform-provider-mobile.tsx`: where mobile `restApiUrl` is set.
  - `docs/background-tasks.md`: how tasks run on mobile in the embedded engine.

## Implementation Status (implemented 2026-06-30)

Implemented and unit-tested (all on Node, `bun run compile` + `bun run test` green):
- `createAssetServerCore` (`packages/node-api/src/lib/asset-server-core.ts`): transport-agnostic core with `serveAsset` / `writeAsset` / `applyDatabaseOps` and the storage cache. Tested in `asset-server-core.test.ts`.
- Express route-wiring (`packages/node-api/src/lib/asset-server-routes.ts`, `attachAssetServerRoutes`). `rest-api`'s `createAssetServer` now delegates to the core + routes so desktop/dev-server behaviour is byte-for-byte unchanged.
- `asset-server` long-running task (`packages/node-api/src/lib/asset-server.worker.ts`): binds a loopback port, streams `asset-server-ready` with the port, stays alive until cancelled. Registered in `task-handlers.ts` and `mobile-worker-entry.ts`. Tested in `asset-server.worker.test.ts` (real express + http: start → ready → GET /asset → cancel).
- Real `net` and `http` shims (`packages/mobile-worker/src/shims/node-net.ts`, `node-http.ts`) over the four TCP host functions plus the inbound `globalThis.__tcpEvent` push. Tested with a mock host in `node-net.test.ts`, `node-http.test.ts`, and `asset-server-over-http.test.ts` (express serving assets over the shimmed http). The mobile bundle builds with express + the shims (`build:bundle`).
- Host-function contract extended: `tcpListen` / `tcpWrite` / `tcpClose` / `tcpStopListening` added to `IHost` and `EXPECTED_HOST_FUNCTIONS`.
- Mobile `restApiUrl` wiring: `useMobileAssetServer` hook (`packages/mobile-frontend`) starts the task and reports the bound port; both `apps/{ios,android}-frontend/src/app.tsx` now feed that URL to `AssetDatabaseProvider`. Tested in `use-mobile-asset-server.test.tsx`.

Design deviation from the written steps (to keep the build sound):
- The core and express route-wiring live in `node-api`, not `rest-api`, because `rest-api` depends on `node-api`; putting a `createAssetServer`-importing worker in `node-api` would create an import cycle. `rest-api` keeps `createAssetServer` as a thin delegating wrapper.

Native TCP layer (done):
- Android (`apps/android-frontend/.../jsengine/TcpHost.java`): `tcpListen`/`tcpWrite`/`tcpClose`/`tcpStopListening` over `java.net.ServerSocket`, accepting and reading on background threads and pushing connection/data/close events into a thread-safe queue. The QuickJS engine run loop (`QuickJsTaskEngine.java`) drains that queue into `globalThis.__tcpEvent` on the engine worker thread and keeps a long-running server task alive (no fixed iteration cap while a listener is open; the loop parks briefly on the event queue when idle).
- iOS (`apps/ios-frontend/.../JsEngine/TcpHost.swift`): the same four functions over POSIX sockets, with the JavaScriptCore engine draining the queue on its context thread whenever an event is enqueued.
- The host-function contract is wired into both native host bridges.

Tested and working on Android: the `1-load-fixture` mobile smoke test opens the seeded 50-asset fixture, asserts the gallery renders all 50 with NO asset-load errors (the previously-ignored thumbnail-fetch errors are gone because the embedded server now serves them), and directly verifies the device asset server returns real JPEG thumbnail bytes over its bound loopback port. Built and run on an Android emulator end to end. The iOS native code mirrors the Android design but was not built/run here (no macOS/Xcode on the dev host).

Verifying the http shim needed two device-path fixes: a real `Stream` base + `util.inherits` in the stream/util shims so express's `send` dependency evaluates in the engine, and standalone (non-stream-subclass) `IncomingMessage`/`ServerResponse` in the http shim (the device `stream` shim is a minimal whole-buffer implementation, so subclassing it left `res.end()` never flushing to the socket).

Deferred / follow-ups (with reason):
- Desktop step 4 (remove the `rest-api-worker` utility process and run the asset server as a task) is NOT done. The desktop worker pool kills any task after a fixed 10-minute per-task timeout (`apps/desktop/src/lib/worker-pool-electron-main.ts`), so a long-running server task in that pool would be killed. Desktop stays on its working utility process, which now delegates to the shared core + routes, so the serving logic is still shared. The Electron asset-display smoke tests (all 22 pass) guard that the refactor did not change behaviour.
- The gallery EDIT path (POST `/apply-database-ops`, which parses a JSON body via `express.json()`) does not yet read the body through the engine's minimal stream shim. Asset DISPLAY (GET `/asset`) and the raw-body POST `/asset` path do not use `express.json()` and work. The metadata-edit body path is a follow-up (and also depends on the mobile storage write layer).
