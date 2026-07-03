# Real LAN sharing on mobile (TypeScript over thin native primitives)

## Overview
LAN database/secret sharing now runs through shared `TaskQueue` background tasks on every platform, but on mobile the `receive-share` / `find-receiver` / `send-payload` handlers are networking-free stand-ins (`packages/mobile-worker/src/lib/lan-share-handlers.ts`) that just wait and report "no peer", because the embedded JS engine has no UDP, no TLS, and no RSA keygen/sign. This plan makes a real mobile transfer work by running the existing `packages/lan-share` TypeScript (`LanShareSender` / `LanShareReceiver`) unchanged inside the embedded engine, exactly the way the asset server runs `express` unchanged over the native TCP shim. It adds TypeScript shims for the Node builtins that `lan-share` imports (`dgram`, `tls`, `https`, and the missing `crypto` functions) and backs them with the smallest possible set of new native primitives (UDP sockets, TLS sockets, RSA keygen/sign) mirroring the existing `TcpHost`. The deliberate design constraint (from the user): implement everything possible in TypeScript and only drop to native where the engine genuinely cannot do the work. The result is one shared protocol code path across desktop, CLI, and mobile, with the same wire format so a mobile device and a desktop interoperate.

## Issues
<!-- Populated later by plan:check -->

## Steps

### A. Native primitive contract (TypeScript side first, so shims are testable against a mock host)

1. **Extend the host interface and expected-functions list.** Edit `packages/mobile-worker/src/lib/host-functions.ts`: add the new native primitive signatures to `IHost` and their names to `EXPECTED_HOST_FUNCTIONS` (so a platform that has not installed one fails loudly). Add, each with a `//` comment on the interface member:
   - UDP: `udpBind(host: string, port: number, broadcast: boolean): string` (returns JSON `{ socketId, port }` or an error envelope), `udpSend(socketId: string, base64: string, host: string, port: number): string | null`, `udpClose(socketId: string): string | null`.
   - TLS: `tlsListen(host: string, port: number, certPem: string, keyPem: string): string` (returns JSON `{ listenerId, port }`), `tlsConnect(host: string, port: number): string` (returns JSON `{ connectionId, peerCertBase64 }` after the handshake, trusting any cert so the JS side can pin), `tlsWrite(connectionId: string, base64: string): string | null`, `tlsClose(connectionId: string): string | null`, `tlsStopListening(listenerId: string): string | null`.
   - Crypto: `cryptoGenerateRsaKeyPair(modulusLength: number): string` (returns JSON `{ privateKeyPem, publicKeyPem }`, pkcs8 + spki), `cryptoSignSha256(privateKeyPem: string, dataBase64: string): string` (returns base64 signature).
   - Requirement: `packages/mobile-worker` type-checks; the mock host in `src/test/shims/tcp-mock-host.ts` (or a new sibling mock) is extended to satisfy the widened interface.

### B. TypeScript shims (the bulk of the work)

2. **Add the `dgram` shim.** Create `packages/mobile-worker/src/shims/node-dgram.ts` modelled on `node-net.ts`. Provide `createSocket(type: "udp4" | ISocketOptions): Socket` returning a `TinyEmitter`-based `Socket` with `bind(port?, cb?)`, `on("message", (buf, rinfo) => ...)`, `send(buffer, offset, length, port, address, cb?)`, `setBroadcast(flag)`, `address()`, and `close()`. Back it with `udpBind` / `udpSend` / `udpClose`. Install a `globalThis.__udpEvent(eventJson)` entry point that routes inbound `{ kind: "message", socketId, address, port, base64 }` events to the owning socket, matching the `__tcpEvent` pattern. Export a default object mirroring `import dgram from "dgram"`.
   - Requirement: type-checks; unit-tested against a mock host (see Unit Tests).

3. **Add the `tls` shim.** Create `packages/mobile-worker/src/shims/node-tls.ts` modelled on `node-net.ts`. Provide a client `connect(port, host, options?, cb?)` that calls `tlsConnect`, stores the returned `peerCertBase64`, emits `secureConnect`, and exposes `getPeerCertificate()` returning `{ raw: Buffer }` (decoded from `peerCertBase64`) so `lan-share`'s cert-pinning check works unchanged. Provide a `Server` used by the https shim: `createServer(options: { key, cert }, connectionListener)` that calls `tlsListen(host, port, options.cert, options.key)` and emits `secureConnection` sockets. Route inbound events via a `globalThis.__tlsEvent` entry point (`connection` / `data` / `close`), reusing the `Socket` shape from `node-net` where practical.
   - Requirement: type-checks; unit-tested against a mock host.

4. **Add the `https` shim.** Create `packages/mobile-worker/src/shims/node-https.ts`. Implement `createServer(options: { key, cert }, requestListener)` by composing the `tls` shim's `Server` with the existing request/response parsing in `node-http.ts` (reuse `IncomingMessage` / `ServerResponse`; factor the connection→request parsing out of `node-http.ts`'s `Server` into a shared helper if needed so both `http` and `https` use it). Implement `request(options, callback)` returning a `ClientRequest`-like object that opens a `tls` client connection, writes the HTTP request line + headers + body, parses the response into an `IncomingMessage`, and exposes the underlying socket (with `getPeerCertificate`) via the `socket` event so `lan-share`'s `req.on("socket", ...)` pinning path works. Support the option subset `lan-share` uses: `hostname`, `port`, `path`, `method`, `headers`, `rejectUnauthorized`.
   - Requirement: type-checks; unit-tested against a mock host.

5. **Implement the missing `crypto` functions.** Edit `packages/mobile-worker/src/shims/node-crypto.ts`: replace the `generateKeyPairSync` NOT IMPLEMENTED stub with an implementation that calls `cryptoGenerateRsaKeyPair(modulusLength)` and returns `{ publicKey, privateKey }` as PEM strings shaped to match how `lan-share-receiver.ts` reads them (`publicKeyEncoding: spki/pem`, `privateKeyEncoding: pkcs8/pem`). Add `createSign(algorithm)` returning an object with chained `update(data)` and `sign(privateKeyPem)` that accumulates the data and calls `cryptoSignSha256`. Keep `createHash` (already pure-JS via `create-hash`). Add both to the default export.
   - Requirement: type-checks; unit-tested against a mock host.

6. **Add `setInterval` / `clearInterval` to the engine globals.** Edit `packages/mobile-worker/src/lib/install-globals.ts`: `lan-share-receiver.ts` broadcasts on a `setInterval`, but the timer shim only provides `setTimeout` / `clearTimeout`. Add `setInterval` / `clearInterval` backed by the same idle-driven queue so `__pumpTimers` re-arms an interval after firing it. Keep the existing behaviour: when a native `setInterval` already exists (Node/Bun test harness) leave it in place.
   - Requirement: type-checks; unit-tested (see Unit Tests).

### C. Bundle wiring: run the real shared handlers on mobile

7. **Alias the new builtins in the bundle build.** Edit `packages/mobile-worker/build-bundle.ts`: add `dgram → src/shims/node-dgram.ts`, `tls → src/shims/node-tls.ts`, and `https → src/shims/node-https.ts` to `aliasMap` (including `node:` variants if the resolver needs them).
   - Requirement: `bun run build:bundle` succeeds (no "Browser build cannot import Node.js builtin" errors for dgram/tls/https).

8. **Register the real handlers and delete the stubs.** Edit `packages/mobile-worker/mobile-worker-entry.ts`: import `receiveShareHandler`, `findReceiverHandler`, `sendPayloadHandler` from `node-api/src/lib/lan-share.worker` (the same real handlers desktop/CLI use) and register them for `receive-share` / `find-receiver` / `send-payload`, replacing the imports of the stub module. Delete `packages/mobile-worker/src/lib/lan-share-handlers.ts` and `packages/mobile-worker/src/test/lan-share-handlers.test.ts`.
   - Requirement: the browser-target bundle still builds (the `lan-share` → `node-api` module graph now resolves dgram/tls/https/crypto to the shims).

### D. Native primitives — Android (Java), mirroring `TcpHost`

9. **Add `UdpHost.java`.** Create `apps/android-frontend/android/app/src/main/java/au/com/codecapers/photosphere/jsengine/UdpHost.java` mirroring `TcpHost.java`. Use `java.net.DatagramSocket` (with `setBroadcast`, `setReuseAddress`) bound per `udpBind`; a background receive loop enqueues `{ kind: "message", socketId, address, port, base64 }` events onto a `LinkedBlockingQueue`; `udpSend` sends a datagram; `udpClose` closes. Expose `pollInboundEvent()` / `awaitInboundEvent(timeoutMs)` / `hasLiveSockets()` / `shutdown()` like `TcpHost`.

10. **Add `TlsHost.java`.** Create `.../jsengine/TlsHost.java` mirroring `TcpHost.java` but with TLS. `tlsListen` builds an in-memory `KeyStore` from the passed cert+key PEM, creates an `SSLServerSocket`, and runs accept/read loops enqueuing `connection` / `data` / `close` events. `tlsConnect` opens an `SSLSocket` with an all-trusting `TrustManager`, captures the server certificate, completes the handshake, and returns `{ connectionId, peerCertBase64 }` (`X509Certificate.getEncoded()` base64); a read loop enqueues `data` / `close`. `tlsWrite` / `tlsClose` / `tlsStopListening` mirror the TCP versions. Share the event-queue plumbing shape with `TcpHost`.

11. **Add `CryptoHost.java`.** Create `.../jsengine/CryptoHost.java`. `cryptoGenerateRsaKeyPair(modulusLength)` uses `KeyPairGenerator.getInstance("RSA")` and returns PEM (pkcs8 private via `PKCS8EncodedKeySpec`/`getEncoded`, spki public via `X509EncodedKeySpec`/`getEncoded`, base64-wrapped with PEM headers). `cryptoSignSha256(privateKeyPem, dataBase64)` loads the pkcs8 key and signs with `Signature.getInstance("SHA256withRSA")`, returning base64. Write against plain `java.security` (no BouncyCastle dependency) so it works on the project minSdk and is JVM-unit-testable, matching the `HostFunctions` convention.

12. **Wire the new hosts into `HostBridge.java`.** Edit `.../jsengine/HostBridge.java`: add `public final UdpHost udp = new UdpHost();`, `public final TlsHost tls = new TlsHost();`, and crypto delegation, plus the JS-callable methods `udpBind/udpSend/udpClose`, `tlsListen/tlsConnect/tlsWrite/tlsClose/tlsStopListening`, `cryptoGenerateRsaKeyPair/cryptoSignSha256` that delegate to the hosts. Add a `//` comment block on each.

13. **Generalise the engine run loop for UDP/TLS.** Edit `.../jsengine/QuickJsTaskEngine.java`: in `runTaskOnWorkerThread`, also poll and deliver UDP and TLS inbound events (new `deliverUdpEvent` / `deliverTlsEvent` helpers invoking `globalThis.__udpEvent` / `globalThis.__tlsEvent`), and treat an open UDP socket or TLS listener as keeping the task alive (extend the `hasLiveListeners()` keep-alive/park condition to a combined `hasLivePorts()` across `tcp` + `udp` + `tls`, and reset `idleAttempts` when any port is live). Ensure `hostBridge.udp.shutdown()` / `hostBridge.tls.shutdown()` run wherever `hostBridge.tcp.shutdown()` runs.

### E. Native primitives — iOS (Swift), mirroring the Android work

14. **Mirror the native layer in Swift.** Create `apps/ios-frontend/ios/App/App/JsEngine/UdpHost.swift`, `TlsHost.swift`, and `CryptoHost.swift` mirroring the Android hosts (UDP via `Network.framework` or BSD sockets; TLS via `Network.framework` / `SecIdentity` with a runtime self-signed identity built from the passed PEM, exposing the peer cert for pinning; RSA keygen/sign via the `Security` framework). Edit `HostBridge.swift` to expose the same `udp*` / `tls*` / `crypto*` methods, and generalise the run loop in `JavaScriptCoreTaskEngine.swift` to drain UDP/TLS events (`__udpEvent` / `__tlsEvent`) and keep the task alive while any port is live, matching step 13.
   - Note: iOS is built but not executed by this repo's automated smoke tests; the user verifies iOS on device. Android is the automated confirmation.

### F. Rebuild artifacts and confirm

15. **Rebuild and copy the worker bundle.** Run `bun --filter=mobile-worker build:bundle` then `bun --filter=mobile-worker copy:bundle` so the regenerated `worker.bundle.js` (now containing the real handlers + shims) is copied into `apps/android-frontend/.../assets/worker.bundle.js` and `apps/ios-frontend/.../worker.bundle.js`.

16. **Full compile, unit, and smoke pass.** Run `bun run compile`, `bun run test`, `bun run build:bundle`, the Android JVM unit tests, and the mobile Android smoke suite. Fix breakage. Confirm no desktop/CLI regression (the shared `lan-share` code is unchanged, but the shims must not alter desktop behaviour because they are mobile-bundle-only).

## Unit Tests

- `packages/mobile-worker/src/test/shims/node-dgram.test.ts` (new): drive `createSocket` against a mock host; assert `bind` calls `udpBind`, `send` calls `udpSend` with base64, `setBroadcast` is honoured, and a simulated `globalThis.__udpEvent` delivers a `message` event with the decoded buffer and rinfo. Follow the `node-net.test.ts` mock-host convention.
- `packages/mobile-worker/src/test/shims/node-tls.test.ts` (new): assert `connect` calls `tlsConnect`, emits `secureConnect`, and `getPeerCertificate().raw` decodes `peerCertBase64`; assert the `Server` calls `tlsListen` with cert+key and routes `__tlsEvent` connection/data/close to sockets.
- `packages/mobile-worker/src/test/shims/node-https.test.ts` (new): assert `createServer` parses a request delivered over a mock TLS connection and writes a response; assert `request` writes a well-formed HTTP request and parses a response, exposing the pinning socket.
- `packages/mobile-worker/src/test/shims/node-crypto.test.ts` (new or extended): assert `generateKeyPairSync` calls `cryptoGenerateRsaKeyPair` and returns the PEMs; assert `createSign(...).update(...).sign(pem)` calls `cryptoSignSha256` with the accumulated data; assert `createHash('sha256')` still works.
- `packages/mobile-worker/src/test/lib/install-globals.test.ts` (extend): assert `setInterval` fires repeatedly across `__pumpTimers` calls and `clearInterval` stops it.
- Android JVM unit tests under `apps/android-frontend/android/app/src/test/java/au/com/codecapers/photosphere/jsengine/`:
  - `CryptoHostTest.java`: `cryptoGenerateRsaKeyPair` returns parseable PEM; a signature from `cryptoSignSha256` verifies against the generated public key with `SHA256withRSA`.
  - `UdpHostTest.java`: bind two loopback sockets, send a datagram, assert a `message` event with the payload/address/port is enqueued.
  - `TlsHostTest.java`: `tlsListen` with a generated cert+key, `tlsConnect` to it over loopback, assert the handshake completes, `peerCertBase64` matches the server cert, and bytes written each way arrive as `data` events.
- Note: the four new TypeScript shims are plumbing modules (not React) and so are unit-tested here; `lan-share.worker` already has unit tests in `packages/node-api` and needs none changed.

## Smoke Tests

- Android loopback round-trip (new mobile smoke test, e.g. `apps/smoke-tests/tests/9-share-roundtrip/test.sh`): within one app on the emulator, run a `receive-share` task and a `find-receiver` + `send-payload` sequence that discover each other over `127.0.0.1` and transfer a payload; assert the receiver's delivered payload equals the sent payload and no `[ERROR]` is logged. The two roles run as real background tasks through the real shims + native primitives. The exact driver (a control-bridge command that enqueues the two tasks, versus a small test-only orchestration handler) is decided during implementation; see Notes.
- Existing Android sender-side tests `apps/smoke-tests/tests/7-share-secret` and `8-share-database` must still pass (now backed by real networking rather than the waiting stubs).
- Desktop non-regression: `bun run test:electron 7-share-secret` and `bun run test:electron 8-share-database` still pass (real two-window transfer), and `bun run test:cli:lan-share` still passes 18/18. The shared `lan-share` package is not modified, so these should be unaffected; run them to prove it.

## Verify

- `bun run compile` type-checks the whole monorepo cleanly.
- `bun run test` passes, including all new shim unit tests and the extended `install-globals` test.
- `bun run build:bundle` (in `packages/mobile-worker`) succeeds with the new `dgram`/`tls`/`https` aliases and the real handlers registered (no Node-builtin import errors).
- Android JVM unit tests pass (`CryptoHostTest`, `UdpHostTest`, `TlsHostTest`, and the existing `HostFunctionsTest`).
- `bun run test:android` runs on the emulator with the new loopback round-trip test passing and tests 7/8 passing; the only acceptable remaining failure is `4-import-photos` (unrelated native media tools, out of scope).
- Desktop `bun run test:electron 7-share-secret` and `8-share-database` pass; `bun run test:cli:lan-share` passes 18/18.
- Grep confirms `packages/mobile-worker/src/lib/lan-share-handlers.ts` is gone and `mobile-worker-entry.ts` registers the real `node-api` handlers.

## Notes

- The whole point is TypeScript-first: the discovery parsing, HTTP endpoints, pairing-code hashing, cert pinning, and even the self-signed certificate construction stay in the existing `packages/lan-share` TypeScript (`lan-share-receiver.ts` already hand-builds the X.509 cert with ASN.1 DER using `crypto.generateKeyPairSync` + `crypto.createSign`). Native is limited to the three things the engine cannot do: UDP datagram sockets, the TLS handshake/record layer, and RSA key generation + signing. SHA-256 is already pure-JS (`create-hash`) and stays in TypeScript.
- Wire compatibility is mandatory and comes for free by reusing `lan-share`: UDP discovery port 54321, broadcast `PSIE_RECV:{port}:{fingerprint}` sent to both `255.255.255.255` and `127.0.0.1`, HTTPS endpoints `GET /pairing-code-hash` and `POST /share-payload`, `codeHash = sha256(pairingCode)`, and SHA-256 cert-fingerprint pinning. A mobile device and a desktop therefore interoperate.
- Emulator networking constraint: the Android emulator's virtual network does not carry LAN broadcast to/from the host, so a real cross-device transfer cannot be verified on the emulator. Confirmation is loopback-only (a receiver task and a sender task in the same app over `127.0.0.1`), which is exactly how the CLI and desktop suites already prove the protocol on a single host. Because `lan-share` already broadcasts to `127.0.0.1`, loopback discovery works unchanged.
- Open question for the smoke test driver: the mobile control bridge currently drives the WebView UI, and a single app instance cannot easily be both sender and receiver through the share/receive dialogs at once. Preferred approach: extend the smoke control bridge with a command that enqueues raw `receive-share` and `find-receiver`/`send-payload` tasks and reports the results, so the round-trip is exercised through the real task path without contriving two UI dialogs. Alternative: a test-only orchestration handler gated behind a test flag. Decide during implementation and keep any test-only code out of the production path where possible.
- The engine run-loop generalisation (step 13/14) is the riskiest native change: the `receive-share` task is long-running (holds a TLS listener + a broadcasting UDP socket for up to 60s) and the `find-receiver` task parks on a UDP socket with no TCP listener, so the keep-alive/idle logic must treat UDP sockets and TLS listeners as "live" or these tasks will be torn down early as "did not settle".
- `setInterval` is added to the engine globals because the receiver broadcasts on an interval; without it the receiver never announces itself. Keep the change minimal and consistent with the existing `setTimeout` pump.
- iOS native code is implemented for parity but confirmed by the user on a device later; this repo's automated smoke run covers Android only. Rebuild and commit `worker.bundle.js` for both platforms since the bundle is checked in.
