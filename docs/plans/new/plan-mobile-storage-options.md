# Mobile Local Storage: Plan (Native-Backed Node `fs`)

## Overview
The Android and iOS frontends (`apps/android-frontend`, `apps/ios-frontend`) currently wrap the real Photosphere UI in Capacitor with `PlatformProviderMobile` returning empty defaults: nothing is wired to local storage. The storage code that reads and writes files is plain TypeScript (`packages/storage`, `packages/node-utils`) that depends on Node's `fs` module, which does not exist in a bare JS engine or the WebView.

The chosen approach: run the existing compiled TypeScript storage code under the native JS engine described in `plan-mobile-background-tasks-options.md` (JavaScriptCore on iOS, QuickJS on Android), and back Node's `fs` module with native implementations of only the `fs` functions the code actually calls (reading, writing, appending, listing, and the supporting calls those need). `FileStorage` (`packages/storage/src/lib/file-storage.ts`) and the `node-utils` helpers run unchanged on top of that native-backed `fs`.

This plan is the concrete realisation of the storage host functions referred to in `plan-mobile-background-tasks-options.md`. It uses that plan's exact machinery: the same `host` bridge, the same engine pool, the same NOT IMPLEMENTED rule, and the same host-function inventory (kept in the plans, not a separate document). The only refinement is where the bridge sits: rather than rewriting `IStorage` into a separate `HostStorage` that calls `host.storageRead` / `host.storageWrite` / etc., we bridge one level lower at the `fs` function boundary, so the real `FileStorage` and `node-utils` code is reused as-is and the storage host functions are `fs`-shaped (`host.fsReadFile`, `host.fsWriteFile`, ...) instead of `IStorage`-shaped. Same bridge, same rules, lower seam.

Serving asset bytes to the WebView is a separate decision, covered in `plan-mobile-serving-options.md`.

Hard rule: no third-party Capacitor plugins. The native `fs` host functions are our own Swift / Kotlin code installed on the engine host bridge, exactly like every other `host.*` function in the background-tasks plan.

## How this fits `plan-mobile-background-tasks-options.md`
- Same `host` bridge: the `fs` functions are members of the same `host` object the engine installs into each pool thread, alongside `host.sendMessage`, `host.isCancelled`, `host.sha256`, and the media tools. They are not a separate mechanism.
- Same engine pool and thread-safety rule: the pool calls `host.fs*` from multiple engine threads at once, so every native `fs` function must be thread-safe, like all other host functions.
- Same NOT IMPLEMENTED rule and message (verbatim): `NOT IMPLEMENTED: native host function "<name>" is not implemented yet on <ios|android>. Implement it ASAP.`, where `<name>` is the host function (for example `fsAppendFile`).
- Same inventory: the `fs` functions listed below are the storage portion of the host-function inventory, and their per-platform status (`not-started` / `stubbed` / `implemented` / `tested`, iOS and Android) is tracked here in this plan. The non-`fs` host functions are inventoried in `plan-mobile-background-tasks-options.md`. There is no separate checklist document.
- Supersedes only the `HostStorage`-over-`host.storage*` sketch in that plan's Concern 1 (step 3) and Concern 1's storage bullet: storage is bridged at the `fs` boundary instead, so `FileStorage` runs unchanged. Everything else in that plan stands.

## Chosen approach: native-backed Node `fs`
- The storage TypeScript (`FileStorage`, `node-utils/fs.ts`) is bundled for the engine unchanged. Its `import * as fs from "fs/promises"` (and `"fs"`, `"stream"`, `"path"`, `"os"`) are redirected at bundle time (esbuild `alias`) to a small mobile `fs` shim.
- The shim is a thin JS module whose functions call `host.fs*` functions through the engine bridge (the same bridge as every other `host.*` call). Each `fs` function maps to one `host.fs*` function.
- Native (Swift on iOS, Kotlin/Java on Android) implements each `host.fs*` function against the app sandbox file system (`FileManager` on iOS, `java.io.File` on Android), the direct analog of Electron's `fs`.
- Only the functions the storage code actually uses are implemented. Anything else throws the loud NOT IMPLEMENTED error, so an unaccounted-for `fs` call is impossible to miss and tells us exactly which native function to write next.

### The `fs` function inventory (the exact native surface to build)
Taken from `packages/storage/src/lib/file-storage.ts` and `packages/node-utils/src/lib/fs.ts`. These, and only these, get `host.fs*` implementations. The host-function name is given in parentheses.
- Read: `readFile` (`fsReadFile`, binary and `utf8`), `access` (`fsAccess`, existence check used by `pathExists`), `stat` (`fsStat`, returns size, mtime, `isFile`, `isDirectory`).
- List: `readdir` (`fsReaddir`, plain names, and `withFileTypes` returning entry name + `isDirectory`).
- Write: `writeFile` (`fsWriteFile`, including the `wx` flag used by the write lock, which must fail with `EEXIST` if the file exists), `mkdir` (`fsMkdir`, recursive), `rename` (`fsRename`), `copyFile` (`fsCopyFile`).
- Append: `appendFile` (`fsAppendFile`), and / or `writeFile` with flag `a`, to cover append-style writes.
- Delete: `unlink` (`fsUnlink`), `rm` (`fsRm`, recursive, `force`).
- Error semantics that callers depend on: missing-path errors carry `code === 'ENOENT'`, the `wx` collision carries `code === 'EEXIST'`. The native bridge must surface these `code` values so existing `try/catch` logic (lock acquisition, `remove`, `pathExists`) behaves the same.

This list is the `fs` checklist: each function above gets a `host.fs*` implementation on iOS and Android, and its per-platform status (`not-started` / `stubbed` / `implemented` / `tested`) is tracked as it lands. Anything not on this list throws NOT IMPLEMENTED until it is added.

### Streaming reads and writes (required, not deferred)
`readStream` / `writeStream` and the `stream` / `createReadStream` / `createWriteStream` / `stream/promises` `pipeline` they rest on are needed by the first handlers, not optional. Hashing reads through `storage.readStream` (`computeHash(await storage.readStream(...))` in `tree.ts`, `verify.worker.ts`, `sync.ts`, `repair.ts`, `replicate.ts`), `serialization` reads through `readStream` (`packages/serialization/src/lib/serialization.ts`), and several worker handlers call `createReadStream` / `createWriteStream` / `pipeline` directly (`save-asset.worker.ts`, `save-assets-batch.worker.ts`, `upload-asset.worker.ts`). They must work from the start.
- First cut, no new native host functions: implement `readStream` / `writeStream` and the `stream` / `pipeline` surface as a pure-JS shim on top of the already-required whole-file `host.fsReadFile` / `host.fsWriteFile`. `readStream` reads the whole file via `fsReadFile` and returns a bundled `Readable` over the bytes; `writeStream` collects the input stream to a `Buffer` and calls `fsWriteFile`. This reuses the native functions already in the inventory, so nothing the handlers need is left throwing.
- Known limitation and later optimisation: the whole-file shim holds a file in memory, which is fine for typical photos but heavy for large video. The upgrade path is true chunked streaming via new native host functions (`fsOpenRead` / `fsReadChunk` / `fsClose` and `fsOpenWrite` / `fsWriteChunk` / `fsClose`); add these only when large-media memory pressure on device demands it. Until then the whole-file shim is the implementation, not a NOT IMPLEMENTED stub.

### Resolved without native code (pure JS, bundled)
- `path` (`dirname`, `join`, `resolve`): pure-JS shim, no native.
- `os.tmpdir` / `getProcessTmpDir`: return an app sandbox temp directory path from the host; no real OS temp on mobile.
- `Buffer`: bytes cross the native bridge as base64 strings; the shim converts base64 to/from `Uint8Array` / `Buffer` polyfill, matching the background-tasks plan's `Buffer` handling.

### Deliberately not implemented (and proven safe to leave loud)
- `*Sync` helpers (`ensureDirSync`, `removeSync`, `copySync`, and the `fsSync.*` they use): the only callers are the desktop and CLI file loggers (`apps/desktop/src/lib/file-logger-electron.ts`, `apps/cli/src/lib/file-logger.ts`), which are not part of the mobile worker bundle. They are left throwing NOT IMPLEMENTED so that if anything ever does pull them onto the mobile path, it fails loudly rather than silently. This is a justified non-implementation backed by the caller audit, not an unfinished gap.

## Unimplemented `fs` functions must fail loudly (never silently)
Any `fs` function the storage code calls but that is not yet implemented in native must produce an immediate, unmistakable error, never a silent `undefined`, a hang, or a wrong result. This is the same rule as the background-tasks plan, applied to the `fs` host functions, and it is the mechanism that tells us exactly which native function to write next.
1. Error message format, verbatim and identical to the background-tasks plan, on both platforms: `NOT IMPLEMENTED: native host function "<name>" is not implemented yet on <ios|android>. Implement it ASAP.` (`<name>` is the host function, for example `fsAppendFile` or `fsRm`.)
2. JS-shim enforcement: the mobile `fs` shim defines every member as a function. Any member whose native counterpart is not installed is a stub that throws the exact message above. A call to a member that does not exist at all (not in the shim) also throws it, via a `Proxy` get-trap default on the shim module so even an unanticipated `fs.<something>` throws loudly rather than returning `undefined`.
3. Native enforcement: the host-bridge dispatch's default / unknown-method branch throws / rejects with the same message including the function name and platform (the background-tasks plan's `notImplemented(name)` helper, reused). A declared-but-unfinished native `fs` function throws the same message from its body.
4. The error propagates as the task's failure (it rejects through `runTask`, native catches it and reports it as the task `errorMessage`, per the background-tasks round trip), so it shows up in the UI and logs, and is written to the native log (`NSLog` / `android.util.Log`) at error level.
5. A native `fs` function in `stubbed` status means exactly this: declared, throws the NOT IMPLEMENTED error, not yet real.

## Native file system scope
The native implementations target the app's own sandbox directories (iOS Documents / Application Support, Android app-private storage): real native files, no runtime permission prompts, survives restarts, backed up as app data. Shared-storage / camera-roll access (`PHPhotoLibrary`, `MediaStore`) is out of scope here and is a later, separable extension of the same bridge. Files are real path-based native files, so this approach is compatible with the `convertFileSrc` serving option in `plan-mobile-serving-options.md`.

## Robust fs conformance testing (all functions, both platforms)
The risk with two native codebases (Swift and Kotlin) plus the JS shim is silent behavioural drift: a function that "works" but returns the wrong bytes, the wrong listing order, or the wrong error `code`. The defence is one data-driven conformance suite, run at three layers against Node `fs` as the oracle, so every `fs` function is proven identical on iOS and Android and cannot diverge unnoticed.

### One shared case list (single source of truth)
Define the suite once as data (a TS/JSON fixture, for example `packages/mobile-fs/src/test/fs-conformance-cases.ts`): a named list of cases, each with a setup (pre-existing files / dirs / bytes), the `fs` call (function + args), and the expected outcome (return shape, or thrown error `code`). The same list is consumed by every layer below, so iOS and Android test the identical scenarios and cannot drift. Cases cover every function and every error path:
- `readFile`: existing binary file (exact bytes), `utf8` file (exact string), missing file (`ENOENT`).
- `writeFile`: new file, overwrite existing, `wx` on new (succeeds), `wx` on existing (`EEXIST`), write into a directory that exists.
- `appendFile`: append to existing file, append creating a new file, binary append (byte-exact).
- `readdir`: empty dir, files only, mixed files + dirs, `withFileTypes` `isDirectory` flags correct, missing dir (`ENOENT`). (Raw order only; `FileStorage` does its own sort.)
- `stat`: file (size, `isFile` true, `isDirectory` false, `mtime` present), directory (`isDirectory` true), missing (`ENOENT`).
- `access`: existing (resolves), missing (`ENOENT`).
- `mkdir`: new nested recursive, already-exists recursive (no throw), path exists as a file (`EEXIST` / `ENOTDIR`).
- `rename`: file, over existing dest, missing source (`ENOENT`).
- `copyFile`: copy bytes, overwrite dest, missing source (`ENOENT`).
- `unlink`: existing, missing (`ENOENT`).
- `rm` recursive: single file, non-empty dir tree, missing with `force` (no throw).
- Cross-cutting: binary bytes round-trip (validates base64 marshalling), a multi-MB file (validates large base64 payloads across the bridge), unicode and spaces in names, deep nesting.
- NOT IMPLEMENTED: a case that calls a deliberately stubbed function asserts the exact NOT IMPLEMENTED message.

### Three layers, all asserting against the Node oracle
1. Oracle + golden generation (Node / Bun): run the case list directly against real Node `fs` in a temp dir. This validates the suite itself and emits a golden fixture of the platform-stable expected outputs (bytes, listing contents, `isFile` / `isDirectory` / `size`, error `code`). `mtime` is asserted as present and monotonic, not exact. The golden fixture is committed and is what the native layers compare against.
2. Shim layer (Bun unit test, off device): run the case list through the mobile `fs` shim over a temp-dir-backed mock host, asserting results equal the golden fixture. This proves the shim marshalling (base64, `code` propagation, `Proxy` guard) independent of any device.
3. Native layer, two ways:
   - Native-isolation tests (XCTest on iOS, JUnit / instrumented on Android): a native harness reads the same case-list JSON and golden fixture, executes each case directly against the native `fs` functions in a temp sandbox, and asserts equality with the golden outputs and `code` values. A native bug is caught here with a native stack trace, independent of the engine and bundle. Same cases on both platforms.
   - Native-via-engine tests (on emulator / simulator, through the smoke harness in `plan-mobile-smoke-tests.md`): load the case list into the real engine (QuickJS on Android, JSC on iOS), run each case through the actual `host.fs*` bridge against the app sandbox, and assert equality with the golden fixture. This proves the whole stack (shim, bridge, native) as it runs on device.

### Why this is robust
- Exhaustive: a case per function and per error `code`, not a happy-path spot check.
- Differential: every native result is compared to the Node `fs` oracle, so behaviour cannot silently diverge from desktop / CLI.
- Layered: shim, native-isolation, and native-via-engine each fail independently, so a break localises to a layer.
- Identical across platforms: one shared case list and golden fixture drive iOS and Android, so coverage cannot drift between them.
- Self-flagging gaps: the NOT IMPLEMENTED case proves a missing function fails loudly rather than passing by accident.

## Steps
1. Create the mobile `fs` shim module (for example `packages/mobile-fs/src/fs.ts`, plus a `fs/promises` entry) that re-exports the inventory functions above, each calling its `host.fs*` function, marshalling `Buffer` as base64, and surfacing `code` (`ENOENT` / `EEXIST`) on thrown errors. Back it with a `Proxy` get-trap so any unlisted member throws the NOT IMPLEMENTED error.
2. Add esbuild `alias` entries to the worker bundle build (the one in `plan-mobile-background-tasks-options.md`) so `fs`, `fs/promises`, `stream`, `stream/promises`, `path`, and `os` resolve to the mobile shims. Confirm `FileStorage` and `node-utils/fs.ts` bundle unchanged against them.
3. Implement the pure-JS shims that need no native: `path`, `os.tmpdir`, the `Buffer`/base64 helpers, and (if the serving plan needs them) the stream shims over `readFile` / `writeFile`.
4. Reuse the background-tasks plan's native `notImplemented(name)` helper and host-bridge dispatch so every unknown or unfinished `host.fs*` function throws the exact NOT IMPLEMENTED message and logs it at error level.
5. Author the shared fs conformance case list and the Node oracle that generates the committed golden fixture (per the testing section).
6. Implement the native `host.fs*` functions on iOS (Swift, `FileManager`): `fsReadFile`, `fsWriteFile` (with `wx` -> `EEXIST`), `fsAppendFile`, `fsReaddir` (plain + `withFileTypes`), `fsStat`, `fsAccess` (`ENOENT`), `fsMkdir` recursive, `fsRename`, `fsCopyFile`, `fsUnlink`, `fsRm` recursive. Each runs against the app sandbox and is thread-safe (the engine pool calls from multiple threads).
7. Implement the same native `host.fs*` functions on Android (Kotlin/Java, `java.io.File`) with identical names, error codes, and thread-safety.
8. Wire the bundle build + copy of the shim-backed worker bundle into both native projects before `cap sync`, alongside the background-tasks bundle wiring (same bundle).
9. Update the per-platform status of each `fs` function in this plan's `fs` inventory as it moves `stubbed` -> `implemented` -> `tested` on each platform.

## Unit Tests
- Mobile `fs` shim test (Bun): with a mock `globalThis.host`, assert each shim function calls the matching `host.fs*` function, marshals `Buffer`/base64 correctly both directions, and propagates `code` (`ENOENT`, `EEXIST`) on errors.
- NOT IMPLEMENTED guard test (JS side): build the shim with one function deliberately not installed, call it, and assert it throws the exact `NOT IMPLEMENTED: native host function "<name>" ...` message; also assert an unlisted member access (`fs.someUnknownFn`) throws the same via the `Proxy` trap.
- fs conformance suite, shim layer (Bun): run the shared case list through the shim over a temp-dir-backed mock host and assert every case equals the Node golden fixture (per the testing section).
- `FileStorage` over the shim (Bun): run the existing `packages/storage` `FileStorage` tests against the mobile shim backed by the mock host, asserting `read` / `write` / `listFiles` / `listDirs` / `fileExists` / `info` / `deleteFile` / `deleteDir` / `copyTo` and the write-lock methods (which depend on `wx` -> `EEXIST`) behave identically to the Node `fs` backing.
- Native `fs` conformance, isolation layer, both platforms:
  - iOS (XCTest): the native harness runs the shared case list and golden fixture directly against the native `host.fs*` functions in a temp sandbox, asserting bytes, listings, `stat` fields, and `ENOENT`/`EEXIST` codes, plus the NOT IMPLEMENTED case.
  - Android (JUnit / instrumented): the same harness, same case list and golden fixture, same assertions including NOT IMPLEMENTED.

## Smoke Tests
- QuickJS parity smoke (off-device, no emulator): build the worker bundle with the `fs` shim, load it into QuickJS via `quickjs-emscripten` with a temp-dir-backed mock host, run the conformance case list and a `FileStorage` round trip (write, append, list, read back) and assert against the golden fixture. Proves the storage code runs under the Android engine family.
- JavaScriptCore parity smoke (macOS, off-device): the same bundle, case list, and round trip through JavaScriptCore, asserting the same golden results, covering the iOS engine. Runs in the iOS XCTest simulator suite where `jsc`/macOS is unavailable in CI.
- NOT IMPLEMENTED parity case: in both parity smokes, call a deliberately unimplemented `host.fs*` function and assert the storage operation fails with the exact NOT IMPLEMENTED message rather than silently.
- On-device fs conformance smoke (native-via-engine, the key on-device proof): using the smoke harness in `plan-mobile-smoke-tests.md`, run the full shared conformance case list against the real native `host.fs*` functions through the engine on a booted Android emulator and iOS simulator, asserting each case equals the golden fixture. Confirms the real `FileManager` / `java.io.File` implementations work end to end and identically on both platforms.

## Verify
- Run all unit tests (shim, conformance shim layer, `FileStorage`-over-shim, and native isolation on both platforms) and confirm they pass, including the NOT IMPLEMENTED guard tests.
- Run the QuickJS and JavaScriptCore parity smokes and the on-device conformance smoke, and confirm every `fs` case matches the Node golden fixture under both engines and on both devices, and that an unimplemented `fs` function fails with the exact NOT IMPLEMENTED message.
- Build the Android and iOS projects with the native `fs` functions and confirm both compile.
- Confirm this plan's `fs` inventory is current: every `fs` function used by the storage code is `implemented` and `tested` on both platforms, and any remaining `stubbed` function throws the NOT IMPLEMENTED error rather than failing silently.
- Run the full repo `bun run test:all` to confirm desktop/CLI storage paths (which keep using the Node `fs` backing) are unaffected.

## Chosen approach (why)
The native storage bridge, realised at the `fs` function level: native `host.fs*` versions of the Node `fs` functions the storage code uses, rather than a separate `IStorage` reimplementation, so `FileStorage` and `node-utils` are reused unchanged. Scoped to the app's own sandbox (iOS Documents / Application Support, Android app-private storage) for the first cut.
- Pro: full control over behaviour, paths, streaming, and range reads. Our own code, no third-party plugin.
- Pro: real path-based native files, the direct analog to Electron `fs`, compatible with `convertFileSrc` serving.
- Pro: smallest native surface, no runtime permission prompts, files backed up as app data, survives restarts.
- Pro: extensible later to shared storage / camera roll (`PHPhotoLibrary` / `MediaStore`).
- Con: two native codebases (Swift and Kotlin) to write and maintain, mitigated by the shared conformance suite above.

## Notes
- Serving is decided separately (`plan-mobile-serving-options.md`). The native `fs` files are real paths, so they are compatible with the `convertFileSrc` serving option; the sandboxed web-storage options were rejected partly because they are not.
- Fits `plan-mobile-background-tasks-options.md`: the `fs` functions are host functions on that plan's `host` bridge, run by that plan's engine pool, governed by that plan's NOT IMPLEMENTED rule and host-function inventory. This plan supersedes only that plan's `HostStorage`-over-`host.storage*` sketch, replacing it with the lower `fs`-level seam so `FileStorage` runs unchanged.
- Native versions of Node `fs` functions are a first-class deliverable, tracked in this plan's `fs` inventory. That inventory plus the NOT IMPLEMENTED rule mean an unimplemented `fs` function is always visible (loud error, failed task, error log) and never silently skipped, which is how we discover the next native function to implement.
- Robustness of the native `fs` is owned by the shared, data-driven conformance suite: one case list and one Node-generated golden fixture, run at the shim, native-isolation, and native-via-engine layers, so every function is proven byte-for-byte and code-for-code identical on iOS and Android.
- Thread-safety: the engine pool calls `host.fs*` from multiple engine threads at once, so every native `fs` function must be thread-safe.
- Key code references:
  - `packages/storage/src/lib/file-storage.ts`: the `IStorage` implementation that runs unchanged on the native-backed `fs`.
  - `packages/node-utils/src/lib/fs.ts`: the fs-extra-style helpers (`ensureDir`, `pathExists`, `remove`, `copy`, `outputFile`) that also run on the shim.
  - `packages/storage/src/lib/storage.ts`: the `IStorage` interface.
  - `apps/android-frontend/src/lib/platform-provider-mobile.tsx`: current stubbed platform provider.
