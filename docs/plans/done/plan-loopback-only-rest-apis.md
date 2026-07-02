# Bind all REST/HTTP servers to loopback only (LAN-share excepted)

## Overview
Photosphere starts several HTTP/REST servers. Some bind to all network interfaces (`0.0.0.0`), which makes them reachable from other machines on the LAN. That is a security exposure: the core asset/REST API, the dev server, and test-control servers are only ever meant to be consumed by the same machine (the local frontend, Electron main, embedded WebView, or local test harness). This plan makes every REST/HTTP server bind to the loopback interface (`127.0.0.1`) so it is only reachable on the local machine. The single deliberate exception is the LAN-share receiver in `packages/lan-share`, whose entire purpose is to serve content to other devices over the LAN; it keeps binding all interfaces. The plan centralises the loopback host as a shared constant, converts each server to use it (or hardens it against non-loopback binding), leaves the LAN-share server unchanged, and adds tests proving the loopback-only invariant.

## Issues
<!-- Leave empty — populated later by plan:check -->

## Current server inventory (research findings)
Behavioural changes needed are marked. Line numbers are indicative and must be re-confirmed when editing.

- `packages/rest-api/src/lib/asset-server.ts:83` — core asset/REST API. Already `listen(port, "127.0.0.1")`. Refactor to shared constant only.
- `packages/node-api/src/lib/asset-server.worker.ts:95,111` — worker-process asset server. Defaults host to `"127.0.0.1"` but accepts an arbitrary `data.host`. Harden so it can never bind a non-loopback host.
- `apps/dev-server/src/index.ts:748` — dev HTTP + WebSocket server on port `3001`. Currently `listen(PORT)` with no host → binds `0.0.0.0`. **Primary behavioural fix.**
- `apps/desktop/src/lib/mcp/worker.ts:119` — MCP server. Already `listen(port, "127.0.0.1")`. Refactor to shared constant (optional consistency).
- `apps/desktop/src/lib/test-control-server.ts:197` — desktop test-control server. Already `listen(port, "127.0.0.1")`. Refactor to shared constant (optional consistency).
- `apps/smoke-tests/lib/control-bridge.ts:217` — smoke-test control bridge. Currently `listen(port)` with no host → binds `0.0.0.0`. **Behavioural fix** (bind loopback; test harness runs on the same machine).
- `packages/node-utils/src/lib/find-available-port.ts:10` — transient free-port probe. `listen(0)` with no host. Bind loopback so the probed port is known-free on loopback.
- `packages/lan-share/src/lib/lan-share-receiver.ts:336` — LAN-share HTTPS receiver, `listen(0)` binding all interfaces. **No behavioural change — the intended exception.** Add a comment documenting why.
- `packages/mobile-worker/src/shims/node-http.ts:576` — embedded-engine HTTP shim, already defaults host to `"127.0.0.1"` and binds via the native TCP bridge (not an OS socket). No change.

## Steps

1. **Add a shared loopback-host constant and helper.**
   - Create `packages/utils/src/lib/network.ts` exporting:
     - `LOOPBACK_HOST` — a `const` string `"127.0.0.1"` (with a `//` comment: the IPv4 loopback address that all local-only servers must bind to so they are unreachable from the LAN).
     - `isLoopbackHost(host: string): boolean` — returns `true` for `"localhost"`, `"::1"`, and any `127.x.x.x` address (including `"127.0.0.1"`); `false` otherwise. Add a `//` comment block describing intent.
   - Add `export * from "./lib/network";` to `packages/utils/src/index.ts`.
   - Requirement: `bun run compile` succeeds; unit tests for this file pass (see Unit Tests).

2. **Fix the dev server to bind loopback (primary fix).**
   - In `apps/dev-server/src/index.ts`, import `LOOPBACK_HOST` from `"utils"` (add to the existing import block, keep all imports at top).
   - Change the listen call at ~line 748 from `server.listen(PORT, () => { ... })` to `server.listen(PORT, LOOPBACK_HOST, () => { ... })`. Keep the existing log message.
   - Add `"utils": "workspace:*"` to `apps/dev-server/package.json` `dependencies` (it currently relies on transitive hoisting for the `from "utils"` import). Run `bun install` from repo root so the workspace link is recorded.
   - Requirement: `bun run compile` succeeds; the dev-server smoke test (see Smoke Tests) passes.

3. **Harden the node-api asset-server worker against non-loopback binding.**
   - In `packages/node-api/src/lib/asset-server.worker.ts`, import `LOOPBACK_HOST` and `isLoopbackHost` from `"utils"`.
   - Change `const host = data.host ?? "127.0.0.1";` to `const host = data.host ?? LOOPBACK_HOST;`.
   - Immediately after resolving `host`, add a guard: if `!isLoopbackHost(host)`, `throw new Error(...)` explaining that the asset server may only bind a loopback address. This makes it impossible for a caller to expose this server on the LAN.
   - Leave the `asset-server-ready` message reporting `host` (now guaranteed loopback).
   - Requirement: `bun run compile` succeeds; unit tests for `assetServerHandler` pass (see Unit Tests).

4. **Refactor the core asset server to the shared constant.**
   - In `packages/rest-api/src/lib/asset-server.ts`, import `LOOPBACK_HOST` from `"utils"` (already a dependency) and replace the literal `"127.0.0.1"` at ~line 83 with `LOOPBACK_HOST`. No behavioural change.
   - Requirement: `bun run compile` succeeds; unit test asserting loopback binding passes (see Unit Tests).

5. **Bind the free-port probe to loopback.**
   - In `packages/node-utils/src/lib/find-available-port.ts`, import `LOOPBACK_HOST` from `"utils"` (already a dependency) and change `server.listen(0, () => { ... })` at ~line 10 to `server.listen(0, LOOPBACK_HOST, () => { ... })`.
   - Requirement: `bun run compile` succeeds; the existing `find-available-port.test.ts` still passes (update it if it asserts a specific bind host).

6. **Bind the smoke-test control bridge to loopback.**
   - In `apps/smoke-tests/lib/control-bridge.ts`, change the listen call at ~line 217 from `this.httpServer.listen(this.options.port, () => { ... })` to `this.httpServer.listen(this.options.port, "127.0.0.1", () => { ... })`. Use the inline literal here (this app has no workspace `utils` dependency and adding one is unwarranted for test infra); add a `//` comment noting the test harness is same-machine only.
   - Requirement: `bun run compile` succeeds; existing CLI and Electron smoke tests still pass (the harness connects from the same machine).

7. **Refactor the already-loopback desktop servers to the shared constant (consistency).**
   - `apps/desktop/src/lib/mcp/worker.ts:119` and `apps/desktop/src/lib/test-control-server.ts:197`: replace the `"127.0.0.1"` literals with `LOOPBACK_HOST` imported from `"utils"`. Confirm `apps/desktop/package.json` depends on `utils` (it depends on `node-utils`, which re-exports nothing relevant); if `utils` is not a direct dependency, add `"utils": "workspace:*"` and run `bun install`. If adding the dependency is undesirable, leave these two literals as-is (they are already loopback-correct) and skip this step.
   - Requirement: `bun run compile` succeeds; Electron smoke tests still pass.

8. **Document the LAN-share exception.**
   - In `packages/lan-share/src/lib/lan-share-receiver.ts` at the `this.httpsServer!.listen(0, ...)` call (~line 336), add a `//` comment stating this server intentionally binds all interfaces because its purpose is to serve paired devices over the LAN, and that this is the sole exception to the loopback-only rule. No code change.
   - Requirement: `bun run compile` succeeds; existing LAN-share tests and `test:cli:lan-share` smoke test still pass.

9. **Run the full verification suite** (see Verify).

## Unit Tests
- `packages/utils/src/test/network.test.ts` (new):
  - `LOOPBACK_HOST` equals `"127.0.0.1"`.
  - `isLoopbackHost` returns `true` for `"127.0.0.1"`, `"127.0.0.5"`, `"::1"`, `"localhost"`.
  - `isLoopbackHost` returns `false` for `"0.0.0.0"`, `"192.168.1.10"`, `"10.0.0.1"`, `""`.
- `packages/node-api/src/test/asset-server.worker.test.ts` (new):
  - Calling `assetServerHandler` with `{ port: 0 }` and a minimal mock `ITaskContext` binds a loopback socket: assert the emitted `asset-server-ready` message `host` equals `LOOPBACK_HOST` and that `server.address().address` is `"127.0.0.1"` (probe by connecting to `127.0.0.1:<boundPort>`). Cancel the context afterwards so the handler returns and the server closes.
  - Calling `assetServerHandler` with `{ port: 0, host: "0.0.0.0" }` rejects/throws (guard from step 3). Do the same for `"192.168.1.10"`.
- `packages/rest-api/src/test/asset-server.test.ts` (new; create `src/test` dir):
  - `createAssetServer({ port, ... })` returns a server whose `server.address().address` is `"127.0.0.1"`. Close the server at the end of the test.
- `packages/node-utils/src/lib/find-available-port.test.ts` (existing): if it asserts the probe bind host, update it to expect loopback; otherwise leave unchanged and confirm it still passes.

Note: `apps/dev-server/src/index.ts`, the MCP worker, and the control bridges are module-scope scripts / classes with side effects and are covered by smoke tests rather than unit tests.

## Smoke Tests
- **Dev-server loopback e2e** (new): a script (e.g. `apps/dev-server/smoke-tests.sh` with a `bun run` wrapper such as `test:dev-server` in root `package.json`, mirroring the existing `test:cli` / `test:electron` pattern) that:
  1. Starts the dev server via `bun run --filter=dev-server start` in the background and waits for `http://127.0.0.1:3001` to accept a connection.
  2. Asserts a request to `http://127.0.0.1:3001/` succeeds (any HTTP response).
  3. Determines a non-loopback IPv4 address from `os.networkInterfaces()`; if one exists, asserts a request to `http://<lan-ip>:3001/` is refused/times out (server not reachable off loopback). If only a loopback interface exists (e.g. minimal CI), log `SKIP` and pass.
  4. Kills the dev-server process on exit.
  Decide during implementation whether to add this to `test:all` (it boots a full worker pool, so it may be kept as a standalone target invoked explicitly). At minimum it must be runnable via a documented `bun run` target.
- **Existing smoke suites unchanged in behaviour**: `bun run test:cli`, `bun run test:cli:encrypted`, `bun run test:cli:lan-share`, and `bun run test:electron` must all still pass after the control-bridge and (optional) desktop-server constant changes. These exercise the test-control servers now bound to loopback, confirming same-machine control still works.
- **LAN-share still works over the LAN**: `bun run test:cli:lan-share` must still pass, proving the receiver remains reachable (the exception is preserved).

## Verify
- `bun run compile` completes with no TypeScript errors.
- `bun run test` (unit tests) passes, including the new `network.test.ts`, `asset-server.worker.test.ts`, and `asset-server.test.ts`.
- The new dev-server loopback smoke test passes (loopback reachable, LAN IP refused, or SKIP when no LAN interface).
- `bun run test:cli`, `bun run test:cli:encrypted`, `bun run test:cli:lan-share`, and `bun run test:electron` all pass.
- Manual grep sanity check: `grep -rn "\.listen(" --include="*.ts" apps packages | grep -v node_modules` shows every production HTTP/HTTPS `listen` call either passes `LOOPBACK_HOST`/`"127.0.0.1"` or is the documented LAN-share receiver.

## Notes
- **Single exception:** only `packages/lan-share/src/lib/lan-share-receiver.ts` binds all interfaces, and only because LAN reachability is its purpose. Its UDP discovery broadcast (`packages/lan-share/src/lib/lan-share-sender.ts` / receiver broadcast on port `54321`) is unrelated to HTTP binding and is left unchanged.
- **Constant home:** `LOOPBACK_HOST` lives in `packages/utils` because it is a platform-neutral string already depended on by `rest-api`, `node-api`, and `node-utils`. `dev-server` gains a direct `utils` dependency (previously transitive). `apps/smoke-tests` deliberately uses an inline literal to avoid adding a workspace dependency to test-only infra.
- **Hardening vs. refactor:** the node-api worker keeps its `host` field for message reporting but is guarded so it can never bind a non-loopback address. This is stronger than a default and directly enforces the requirement even if a future caller passes a host.
- **Mobile embedded engine:** the `mobile-worker` HTTP/net shims already default to `127.0.0.1` and serve over the native TCP bridge rather than an OS-level socket, so mobile is not LAN-exposed and needs no change.
- **Optional step 7:** refactoring the already-correct desktop servers to the shared constant is purely for greppability/consistency. If it would force an unwanted new dependency, it can be skipped without weakening the security guarantee.
- **Dev-server e2e cost:** if booting the full dev server in a smoke test proves flaky or slow, the team may instead rely on the `LOOPBACK_HOST` constant plus code review for the dev-server line, since the behavioural guarantee there is a single well-typed argument. The plan keeps the e2e as the preferred proof.
