# Port the Photosphere core to Zig, one package at a time

## Overview

Photosphere's core is sixteen TypeScript packages under `packages/`, shared by the CLI, the Electron desktop app, and the iOS and Android apps. This plan replaces those implementations with Zig, **in place, one package at a time**, behind the interfaces that already exist. `packages/storage/src/index.ts` keeps exporting `IStorage`, `FileStorage` and `createStorage`; what changes is that the class bodies forward to a Zig library instead of doing the work themselves. Every consumer of a ported package is untouched.

This replaces an earlier version of this plan that built a parallel Zig tree (`zig/`, `apps/desktop-zig/`, `apps/android-frontend-zig/`, `apps/ios-frontend-zig/`) alongside the TypeScript one. That version was attempted and abandoned. It is recorded here as the approach not to take, and why, in "Why this can only be done incrementally" below.

## Why this can only be done incrementally

**This was already attempted twice, each time as a single piece of work, and neither attempt finished.** Both were made against the parallel-tree version of this plan, with the whole forty-five steps treated as one session.

The first ran in the `zig-core-port` worktree and got a long way: seven spikes and roughly 27,000 lines of Zig across sixteen module directories, with about 1,030 test blocks (see the Notes for exactly what is in there and how to treat it). It still stopped well short of a working application, and none of it was ever committed or shown to pass. The second ran in the main working copy and stopped at the end of step 2, the `CLAUDE.md` amendments and the provisional toolchain pin.

The lesson from both is the same, and it is the reason this plan exists in its current form. The port is roughly fifty thousand lines across sixteen packages. It is not a single piece of work, no session is going to hold it, and the failure is not one of effort: writing tens of thousands of lines of Zig that no application runs produces no evidence that any of it is right. It must never be attempted as one piece again.

The parallel-tree approach produced nothing testable until roughly two thirds of the way through: forty-five steps, with the first runnable artefact at step thirty. Everything before that was Zig code whose only evidence of correctness was its own unit tests, checked against the TypeScript through committed fixtures and comparison scripts that themselves had to be built and trusted. That is not a plan that can be stopped at, and a port of fifty thousand lines will be stopped at, many times.

The incremental approach inverts the evidence. After each increment the repository's existing smoke suites run against the real apps on every platform, and they exercise the Zig code because the TypeScript that used to do the work now calls into it. There is no new comparison infrastructure to build and no second implementation to keep in step, because at any moment there is exactly one implementation of each ported package.

The cost is real and is stated up front rather than discovered: bridging asynchronous and stream-based interfaces across a native boundary is more total work than a clean cut would be. That cost buys a plan where every step ships.

**No step in this plan may be taken out of order to "get ahead" on a later package.** The increment contract below is the whole plan.

## The increment contract

One increment is one package, or one clearly separable half of a package (see step 8 for why halves matter). An increment is complete only when all of the following hold:

- `bun run compile` passes and `mise exec -- zig build test` passes, including the leak, `ReleaseSafe` and allocation-failure passes described in the phase 1 preamble.
- `bun run test` passes. The ported package's existing Jest suite is not rewritten. It now tests the Zig implementation through the same exported names, which is the point.
- **Every smoke suite that reaches the ported package passes, on every platform that runs it.** For most increments that means all of: `bun run test:cli`, `bun run test:cli:encrypted`, `bun run test:cli:lan-share`, `bun run test:cli:hash-cache`, `bun run test:lan-share:cli-desktop`, `bun run test:electron`, `bun run test:and`, and `bun run test:ios` on macOS. The counts must match what the same suites reported before the increment. A suite that gets faster or slower is fine; a suite that loses a test is not.
- `bun run tev -- --force` passes.
- The TypeScript implementation the increment replaces is deleted, not left beside the Zig one. Two implementations of the same function is the thing this plan exists to avoid.

If a smoke suite fails, the increment is not finished. It is not "finished with a known issue", and the next increment does not start. This is the rule that makes the plan safe to stop at any point.

## How TypeScript reaches Zig

There are three runtimes in this repository and only two of them can call native code. This determines which packages can be ported and in what order, so it is settled here rather than per-step.

**CLI and Electron main process: a Node-API addon.** Both are Node-compatible runtimes that load `.node` addons, and both run the packages directly. Async is handled with `napi_async_work`, so a Zig call runs on a worker thread and resolves a real Promise, leaving the event loop free. Buffers cross by pointer with `napi_get_buffer_info` inbound and `napi_create_external_buffer` outbound. Native objects are held by an opaque handle wrapped with `napi_wrap` plus a finalizer, so the Zig object is freed when the JavaScript wrapper is collected. Electron's Node ABI differs from Bun's, so one addon binary is built per ABI and each asserts `process.versions.modules` at load, failing with both numbers in the message.

**Mobile: the existing host bridge.** The mobile apps run the same packages inside QuickJS on Android and JavaScriptCore on iOS, driven by `packages/mobile-worker`. Neither engine can load a `.node` addon. The route is instead one new function on the existing `host.*` bridge in `packages/mobile-worker/src/lib/host-functions.ts`, dispatching into the Zig static library linked into the app. The bridge already carries binary as base64 strings (`fsReadFile`, `fsWriteFile`, `tcpWrite`, `tlsWrite`, `udpSend` all do), so this follows an established pattern rather than inventing one.

**The renderer and the WebView cannot call Zig at all.** `packages/user-interface` runs in a browser context with no native route and no plausible one. Any package it imports therefore cannot be ported wholesale; only the half the browser does not use can move. This rules out `packages/utils` (thirty-five imports from `user-interface`) and `packages/encryption` (imported by `configure-secrets-modal.tsx`) as whole-package increments, and both are split accordingly below. Check this before starting any increment, not after.

**Streams never cross the boundary.** `IStorage.readStream` returns a Node `Readable` and `writeStream` takes a `NodeJS.ReadableStream`, with sixty-seven non-test call sites between them. The stream objects stay in TypeScript. A `Readable` subclass calls an addon `readChunk(handle, offset, n)`; `writeStream` consumes its input stream in TypeScript and pushes chunks in. Zig only ever sees byte ranges.

## Phase 0: foundations and three blocking spikes

1. **Amend the `CLAUDE.md` rules this plan collides with.** Three bullets currently forbid the work outright. Amend all three in one edit:
   - "THIS REPOSITORY USES TYPESCRIPT AND SHELL SCRIPT. NOTHING ELSE." Add Zig as a permitted language, scoped to `zig/`.
   - The bullet banning hand-written wire protocols and request signing that "a maintained library already does". Amend it so that a protocol implementation shipping in the Zig standard library (`std.http.Client`, `std.http.Server`, `std.crypto.tls`, `std.net`, `std.compress`) counts as a maintained library, exactly as `node:http` and `node:tls` do on the TypeScript side. Anything outside the standard library still requires a vendor library: S3 and SigV4 from the AWS C runtime, RSA and AES-CBC and PEM from OpenSSL or BoringSSL, BSON from libbson.
   - The same bullet's ban on reimplementing a library's behaviour. Amend it to permit a from-scratch implementation of a presentation surface whose output contract is pinned by this repository's own smoke tests rather than by a wire format. This covers terminal output only and never anything crossing a process or machine boundary.

   Add a bullet stating that Zig files under `zig/` follow the porting rules in `docs/zig-port/README.md`. Do not touch the bullets covering `.githooks/pre-commit`, `scripts/install-hooks.sh` and `scripts/test-everything-parallel.sh`; those files stay frozen.

2. **Pin the Zig toolchain provisionally.** Run `mise ls-remote zig`, pick the latest stable release, add `zig = "<version>"` to `mise.toml` under `[tools]`, and record it in `docs/zig-port/README.md` marked **provisional until step 7 passes**. Step 7 is the first thing that tests the release against Xcode 14.2 and macOS 12.7.6. Every Zig command from here is run as `mise exec -- zig ...`. Verify with `mise exec -- zig version`.

3. **Create the Zig workspace skeleton.** Create `zig/build.zig`, `zig/build.zig.zon` and `zig/package.json`, with `zig/lib/psi-core/src/` holding one subdirectory per ported package and `zig/apps/psi-node/src/` holding the Node-API addon. Build steps are named for what they produce: `lib`, `node`, `mobile-android` (all three Android ABIs together, because Gradle needs them in one `jniLibs` tree), `mobile-ios` (both iOS targets lipo'd, because Xcode needs one fat library), and `test`. The default `zig build` builds `lib` and `node` for the host only.

   `zig/package.json` declares `{"name": "zig", "scripts": {"compile": "mise exec -- zig build --summary none", "test": "bash ./run-tests.sh", "clean": "rm -rf zig-out .zig-cache"}}`. Add `"zig"` to the root `package.json` `workspaces` array. Not `"zig/*"`: the package file is at `zig/package.json`, so that glob would match `zig/apps` and `zig/lib` and pick up nothing.

   `package.json`, `mise.toml`, `what-changed.json` and everything under `scripts/` are in `alwaysPaths` in `what-changed.json`, so each edit to them forces a full suite run. Add `"zig"` to the `paths` of the existing `compile` and `test` targets in the same edit, and confirm with `bun run everything:plan` that a Zig-only change now runs them. Without this a Zig-only change matches no target and runs nothing.

   Run `bun install`, then `bun run compile` and `bun run test`, and confirm the Zig tree is visibly built rather than assuming the workspace entry works.

4. **Write the porting rules document, `docs/zig-port/README.md`.** One Zig file per TypeScript file, same relative path, base name with `-` replaced by `_`. Every Zig file opens with `// Port of packages/<pkg>/src/lib/<file>.ts`. Declaration order and function names match the TypeScript. Interfaces lose the `I` prefix and become a struct with a vtable (`IStorage` becomes `Storage`). TypeScript doc comments are ported verbatim. Every allocating function takes `allocator: std.mem.Allocator` first. `throw` becomes a Zig error in an error set. The repo comment rules in `CLAUDE.md` apply unchanged.

5. **Record the async decision and the cancellation contract that follows from it.** Zig has no `async`/`await`, so every `async function` becomes blocking and the concurrency `packages/task-queue` gets from the event loop comes from a `std.Thread.Pool`. Blocking threads cannot be interrupted from outside, so cancellation is cooperative and must be designed now, not when the task queue is ported:
   - Every handler receives a `*const CancelToken` on its `TaskContext`: an atomic flag plus a `std.Thread.ResetEvent`. `cancelTasks(source)` sets the flag on every token belonging to that source and signals the event.
   - Every handler checks `context.cancel.requested()` at each iteration of any loop over files, assets, records or chunks, and returns `error.Cancelled`. Wherever the TypeScript checks a cancellation signal the Zig checks the token in the same place.
   - Every blocking call that can wait indefinitely takes a deadline: `SO_RCVTIMEO` and `SO_SNDTIMEO` on sockets, `ResetEvent.timedWait` instead of `wait`, a request timeout on AWS CRT requests. One named shared constant.
   - The two long-lived handlers (the asset server and the LAN share receiver) each own a listening socket; cancellation sets the token and closes the socket, and the accept loop exits on the next wake-up.
   - Shutdown means: cancel every token, wait for every pool thread with a bounded timeout, then free. A thread that has not returned by the deadline aborts loudly rather than having memory freed underneath it.

6. **SPIKE: prove the Node-API addon route, and settle the compiled-CLI question.** This is the enabler for every increment on CLI and Electron, so it comes before any porting and not at the end.

   Build a throwaway addon in `zig/spikes/napi/` exporting one synchronous function and one asynchronous one using `napi_async_work`. Prove all of:
   - It loads and is callable from a Jest test under `ts-jest`, which is how every package's `test` script runs.
   - It loads and is callable from the Electron main process on the pinned Electron version, and can invoke a callback on the main thread from a Zig worker thread using `napi_threadsafe_function`, which is what streaming task progress will require.
   - It cross-builds for `x86_64-linux`, `x86_64-windows`, `x86_64-macos` and `aarch64-macos`, which are the four targets `electron-builder` packages for. A cross-build failure found at packaging time is found too late.
   - `electron-builder` packages it: add it to `apps/desktop/package.json`'s `build.extraResources` or `build.files`, build a packaged artefact, unpack it and confirm the addon for that platform is present and loadable outside the asar.

   **The open question this spike must answer:** `apps/cli` ships as a single executable via `bun build --compile` (see `build-linux` and friends in `apps/cli/package.json`), and whether a `.node` addon can live inside such a binary is not known. Determine it. If it cannot, the options are to ship the addon next to the binary and change the release layout `bin/<arch>/<platform>/psi` that the `upgrade` command depends on, or to accept that the compiled CLI is the last thing ported. Record the finding and the chosen option in `docs/zig-port/README.md`. Note that the CLI smoke suites default to `bun run start --` and not the compiled binary (`USE_BINARY=false` at `apps/cli/smoke-tests.sh:81`), so this does not block the spike, but it does block shipping.

   Pin Electron to an exact version in `apps/desktop/package.json` (it currently floats at `^40.0.0`) and record the ABI number in `docs/zig-port/README.md`. A floating minor that crosses an ABI boundary breaks the addon at load with no build error.

   If the addon route fails outright, stop and report. The fallback (spawning a Zig CLI as a child process with a line-delimited JSON protocol) would need a subcommand for each of the roughly forty direct `ipcMain.handle` calls in `apps/desktop/src/main.ts`, which is a phase of its own and is a decision for the human.

7. **SPIKE: prove Zig links into the mobile apps, and fix the toolchain pin.** Build a one-function static library for `aarch64-linux-android`, `armv7a-linux-androideabi` and `x86_64-linux-android`, link all three into `apps/android-frontend`, and call it over JNI. Do the same for `aarch64-ios` and `x86_64-ios-simulator` linked into `apps/ios-frontend`, called from Swift. This must be done against the pinned iOS environment named in `CLAUDE.md`: Xcode 14.2 and macOS 12.7.6. The spike passes when a native unit test on each platform calls into Zig and gets a value back, on device or simulator as well as in the linker.

   This decides the toolchain version step 2 pinned provisionally. If Xcode 14.2's linker rejects what the release emits, work backwards through the release list until one links, re-pin `mise.toml`, and record every version tried with its exact error. If none links, stop and report: raising the Xcode or macOS requirement is forbidden by `CLAUDE.md` and is the human's decision.

   Do this spike early even though mobile is the last thing ported. It is the single failure that would invalidate the mobile half of the port's value, and it is cheap to run now. Finding out after a dozen packages are ported is the worst possible time.

8. **SPIKE: port the first increment end to end and prove the smoke suites pass on all four platforms.** This is the proof that every later increment in this plan will work. It is deliberately the most expensive increment in the plan, because it builds the machinery all the others reuse.

   **The increment is the synchronous half of `packages/serialization`:** `BinarySerializer`, `BinaryDeserializer`, `CompressedBinarySerializer`, `CompressedBinaryDeserializer` and `UnsupportedVersionError` (lines 167 to 540 of `packages/serialization/src/lib/serialization.ts`). The asynchronous `save`, `load`, `loadVersion` and `verify` stay TypeScript for now and call the Zig-backed classes, so this increment needs no async binding and no stream binding.

   It is the right first increment for four reasons, each of which is a criterion to apply when choosing any later one:
   - It is small and self-contained: one file, and the sync half of it is buffer in, buffer out.
   - No frontend package imports `serialization`, so there is no browser code path that cannot reach Zig.
   - It is consumed by `bdb`, `merkle-tree` and `api`, all of which run on mobile inside QuickJS, so the mobile smoke tests genuinely exercise the Zig code rather than passing trivially.
   - The on-disk format it produces is asserted by the CLI smoke tests through `psi root-hash` and `psi summary`, so a format divergence fails loudly and immediately.

   `packages/fuzzy-match` is smaller and looks like the obvious first choice. It is not: its only consumer is `apps/cli/src/lib/init-cmd.ts`, so it is unreachable on mobile and its passing smoke suites would prove nothing about three of the four platforms.

   What this increment must build:
   - The Zig implementation in `zig/lib/psi-core/src/serialization/serialization.zig`, with its unit tests ported from `packages/serialization/src/test/`.
   - The Node-API bindings in `zig/apps/psi-node/`, on the step 6 spike.
   - The one new `host.*` function in `packages/mobile-worker/src/lib/host-functions.ts` that dispatches into the Zig static library, plus its native adapter on Android and iOS, on the step 7 spike.
   - A single loader in `packages/serialization` that picks the addon or the host bridge at runtime, so no later increment has to solve platform selection again. Where this loader lives is a decision this step makes and records in `docs/zig-port/README.md`; it must not be duplicated per package.
   - The rewritten class bodies, forwarding to whichever route the loader selected, with the TypeScript implementation deleted.

   The spike passes when every one of these reports the same counts it reported before the increment: `bun run test`, `bun run test:cli`, `bun run test:cli:encrypted`, `bun run test:cli:lan-share`, `bun run test:cli:hash-cache`, `bun run test:lan-share:cli-desktop`, `bun run test:electron` (34 tests under `apps/desktop/smoke-tests/`), `bun run test:and` (41 tests under `apps/smoke-tests/tests/`) and `bun run test:ios` (the same 41 on macOS). The numbers to match are whatever the suites report on the day, not the numbers written here.

   **If this spike does not pass on all four platforms, stop and report.** Every increment below rests on it. Do not begin step 9 while any suite is red, and do not begin it on the argument that the failure is unrelated.

## Phase 1: leaf increments

Each increment from here follows the increment contract above, and additionally:
- Every new function has a `test` block in its own file, using `std.testing.allocator` so a leak fails the test rather than being invisible.
- `mise exec -- zig build test -Doptimize=ReleaseSafe` passes as well as the plain run.
- Every function that can fail to allocate has a `std.testing.checkAllAllocationFailures` test. This is coverage with no TypeScript equivalent, because TypeScript never sees an allocation failure.
- Where the module links a C library, the tests also run under Valgrind if it is present. `std.testing.allocator` sees only Zig-side allocations and cannot see a leak inside a C library. `zig/run-tests.sh` runs all three passes and skips the Valgrind one with a printed message, never silently.

9. **Finish `packages/serialization`:** port `save`, `load`, `loadVersion` and `verify`. These take an `IStorage` and are asynchronous, so this is the first increment to use the `napi_async_work` binding for real. `loadVersion` reads the first four bytes through `storage.readStream`, which is the first place the stream rule from "How TypeScript reaches Zig" applies: the `Readable` stays in TypeScript.

10. **Port `packages/fuzzy-match`** to `zig/lib/psi-core/src/fuzzy_match/fuzzy_match.zig`. Forty-seven lines, `levenshteinDistance` and `fuzzyMatch`. Port the existing Jest cases as Zig `test` blocks, value for value. Reached only by the CLI smoke suites, and that is fine now that step 8 has proved the mechanism on all four platforms.

11. **Port `packages/merkle-tree`:** `merkle_tree` (1,969 lines, the bulk), `merkle_diff`, `visualize`, `compare`, `traverse`, `buffer_map`, `buffer_set`. The persisted tree and its root hash are asserted by the CLI smoke tests through `psi root-hash` and `psi summary`, which is this increment's strongest evidence.

12. **Port the Node-side half of `packages/encryption`:** `encryption_constants`, `encryption_types`, `encrypt_buffer`, `encrypt_stream`, `key_utils`. The format is AES-256-CBC with an RSA-wrapped key (`ENCRYPTION_TYPE` is `A2CB`).

    **Zig's standard library has no CBC mode.** `std.crypto` ships the AES block functions and the CTR and AEAD modes and nothing else. Writing CBC by hand is hand-writing a crypto mode and is banned. CBC, RSA key handling and PKCS#8/SPKI PEM parsing all come from the OpenSSL or BoringSSL link this increment introduces. State that in `docs/zig-port/README.md`, because "AES is in std" is exactly the assumption that leads someone to write the mode themselves.

    `packages/user-interface` imports this package from `configure-secrets-modal.tsx`, so the browser-reachable half stays TypeScript. Identify exactly which exports the renderer uses before starting, and port only the rest. `bun run test:electron` is the suite that catches getting this wrong.

13. **Port the Node-side half of `packages/utils`:** `sleep`, `retry`, `retry_or_log`, `try_or_log`, `swallow_error`, `uuid_generator`, `random_uuid_generator`, `test_uuid_generator`, `wrapped_error`, `fatal_error`, `log`, `timestamp_provider`, `mock_timestamp_provider`, `random_generator`, `format`, `log_exceptions`, `batch_generator`, `image`, `reverse_geocode`. `IUuidGenerator` and `ITimestampProvider` become vtable structs with the same deterministic test implementations the smoke tests rely on through `NODE_ENV=testing`.

    `packages/user-interface` has thirty-five imports from this package and `packages/mobile-frontend` has two. The browser-safe half stays TypeScript. Enumerate those imports first and port only what is left.

    `reverse_geocode` performs HTTP. Use `std.http.Client`, not the AWS CRT, and test it against a local `std.http.Server` returning a canned response so no test reaches the network. Record in `docs/zig-port/README.md` where each platform's root certificates come from.

## Phase 2: storage and the database

14. **SPIKE: prove S3 and plain HTTP work from Zig.** `packages/storage` uses `@aws-sdk/client-s3` and `@aws-sdk/lib-storage`. Zig has no AWS SDK and hand-writing SigV4 is banned, so the only acceptable route is linking AWS's own C runtime: `aws-c-s3` and its stack (`aws-c-auth`, `aws-c-http`, `aws-c-io`, `aws-c-cal`, `aws-c-compression`, `aws-c-sdkutils`, `aws-c-common`, `aws-checksums`), plus `s2n-tls` on Linux and Android and the Apple TLS stack on macOS and iOS.

    The spike passes when a throwaway program in `zig/spikes/s3/` can put an object to the local S3 emulator (`bun run s3-emulator`), get it back byte-identical, list a prefix and delete it, **and** the same build links for all five mobile targets. If the CRT cannot be built for Android or iOS, stop and report: every workaround is banned and the fallback is the human's decision.

    Pin every C dependency in `zig/build.zig.zon` by exact tag and content hash, never a branch or floating ref, so a swapped upstream artefact fails the hash check rather than being fetched silently. Record each library's pinned version, repository and licence in `docs/zig-port/README.md`, plus a named check to run before each release against the upstream advisory feeds. This stack links into every shipped binary on every platform, so a CVE in it is a CVE in Photosphere.

15. **Port `packages/storage` as a single increment, not four.** `IStorage` is seventeen asynchronous methods, two of which carry Node streams, and `FileStorage`, `CloudStorage`, `EncryptedStorage` and `StoragePrefixWrapper` compose with each other inside `createStorage`. Splitting them means building a boundary between Zig and TypeScript implementations of the same interface, in both directions, and then deleting it again. Port them together.

    Files: `storage` (the vtable, `IListResult`, `IFileInfo`, `IWriteLockInfo`), `file_storage`, `walk_directory`, `mock_storage`, `cloud_storage`, `s3_path`, `s3_range_readable_stream`, `encrypted_storage`, `storage_prefix_wrapper`, `storage_factory`, `read_encryption_header`. `MockStorage` is exported from the package index and used widely by tests; port it so the Zig tests have the same in-memory implementation, but keep the TypeScript one too, since Jest suites that use it never need to touch Zig.

    Tests this increment must have, since most of these have no Jest suite to port:
    - `FileStorage`: every vtable method against a temporary directory, `info` on a missing file returning `undefined` rather than erroring, `read` of a missing file, `listFiles` paging with `max` smaller than the directory, `deleteDir` on a non-empty tree, `copyTo` overwriting an existing destination, and a non-ASCII file name round-tripping through `write`, `listFiles` and `read`.
    - `CloudStorage` against the local emulator: multipart upload interrupted after the second part leaving no partial object visible and a retry from scratch succeeding; a multipart upload cancelled through the step 5 token returning `error.Cancelled` and aborting rather than completing; a ranged read starting past end-of-file and one straddling it, each matching what `s3-range-readable-stream.ts` does today (read that file, do not assume, and name the TypeScript behaviour in a comment); and distinct named errors for a missing key, a missing prefix and invalid credentials.
    - `EncryptedStorage`: buffer and stream round trips; `info` reporting whichever length the TypeScript reports; an unsupported header version or type failing with the named error; a plaintext file read through encrypted storage failing rather than returning rubbish; a read with the wrong key failing loudly.
    - `StoragePrefixWrapper`: every method prepending the prefix; `listFiles` and `listDirs` stripping it; a prefix with and without a trailing separator behaving identically; a `..` escape rejected.
    - `read_encryption_header`: a valid header, a file shorter than the header, a wrong magic tag, an empty file.
    - `storage_factory`: `fs:` with absolute and relative paths, `s3:bucket:/path` with and without a leading slash, a bare path with no scheme, an unknown scheme, an empty descriptor, and a scheme with no body. The CLI smoke tests pass these strings on the command line, so each case names its expected result or error.
    - Write locks: two owners racing with exactly one winning; the loser succeeding after release; an expired lock being acquirable by a second owner; `refreshWriteLock` extending an expiry so the second owner still fails; and `refreshWriteLock` by a non-owner failing. Drive the clock from the `TimestampProvider` vtable rather than sleeping.

16. **Add the path sandbox, `zig/lib/psi-core/src/storage/path_sandbox.zig`.** `PathSandbox.java` and `PathSandbox.swift` confine the mobile engine's filesystem access to the app's own directories. Once `FileStorage` is Zig, that confinement has to exist in Zig or the library gets the app's whole sandbox with nothing checking it.

    Port it from the Java and Swift, configured with the roots the library may touch and consulted by `FileStorage` before every open, create, delete and directory walk when running on mobile. A path outside the roots is a named error, never a silent failure. On desktop and CLI it is configured with no restriction, matching today's behaviour, and `docs/zig-port/README.md` says so explicitly so nobody reads the unrestricted desktop case as the sandbox being unused. Port the Java tests plus: an absolute path outside the roots, a relative path climbing out with `..`, a symlink inside a root pointing outside it (checked after resolution, not before), a path that normalises into a root only after resolving `..`, and a non-ASCII path inside a root being allowed.

17. **Port `packages/bdb`,** in dependency order: `shard` (452), `merge_records` (207), `update_fields` (44), `update_metadata` (71), `merkle_tree` (330), `merkle_tree_ref` (161), `collection` (735), `sort_index` (2,609, the largest single file in the port), `database` (196), plus `mock_database` and `mock_collection`. BSON comes from libbson, not from a hand-written codec.

    **Before any collection code is ported, write a per-type BSON conformance test.** The two BSON implementations agree on the specification but not necessarily on what it leaves open, and every database in the wild was written by the `bson` npm package. Enumerate the types by reading what `packages/bdb` actually writes, not by listing the specification, and record the enumeration in the module's `README.md`. At minimum: the binary subtype the npm package emits for a `Buffer` (subtype 0 and subtype 2 have different framing) against what libbson emits and accepts; integers at the int32/int64 boundary, including a value that fits in 32 bits, to find out whether one implementation narrows it and the other does not; a JavaScript number that is integral but stored as a double; dates; `null` against a missing field; an empty document, an empty array and an empty string; a string with non-ASCII and one with an embedded NUL; and a document nested more than one level deep. A mismatch must name the type, not surface as "a database failed to open".

    Only then the whole-database test: open a database written by the TypeScript `bdb` (build one with `bun run --filter=bdb-cli`) and assert every record and every sort index reads back identically. That is the backstop, not the defence.

    `apps/bdb-cli` and `apps/mk-cli` depend on `packages/bdb`, `packages/merkle-tree` and `packages/storage`. They are not in scope for this port, and because the packages are replaced in place rather than duplicated, both tools now run on the Zig implementations. Their smoke coverage is part of `bun run test:cli`, which must still pass.

18. **Port `packages/vault`:** `vault`, `plaintext_vault`, `get_vault`, `keychain_types`, `macos_keychain_vault`, `linux_keychain_vault`, `windows_keychain_vault`. The keychain backends shell out today to `security`, `secret-tool` and PowerShell; keep that with `std.process.Child`, passing arguments as an argv array with no shell in between, exactly as the TypeScript does.

    Two things about secrets crossing the process boundary have to be said rather than inherited silently:
    - The macOS path passes the secret JSON as an argument to `security add-generic-password -w <json>`, and process arguments are readable by other processes. The Linux path avoids this by piping to `secret-tool store` on stdin. Port both verbatim so behaviour matches, record the macOS exposure in `docs/zig-port/README.md` as a pre-existing property this port carries over unchanged, and raise it with the human when this increment lands. Do not "fix" it here: changing how secrets reach the macOS keychain changes what existing installations can read back.
    - The Windows path builds a PowerShell script as a string with the service, account and secret interpolated into single-quoted literals, escaped by doubling each `'`. That escaping is the only thing between a secret and PowerShell's parser. Port it as a named function in its own file with the TypeScript's exact rule, and test it against `'`, `''`, a backtick, `$(...)`, `$env:X`, a newline, a NUL and a non-ASCII character, plus a real store-and-retrieve round trip when running on Windows. If the round trip shows the doubling rule is insufficient for some value, stop and report rather than inventing a different scheme: it would mean the TypeScript has the same hole.

    Respect `PHOTOSPHERE_VAULT_DIR` and `PHOTOSPHERE_VAULT_TYPE`, which the smoke tests set. Test `get_vault` selection directly: each valid type selecting its backend, an unset variable selecting the platform default on each platform, and an unrecognised value failing with a named error rather than falling back silently.

    On mobile there is no `security`, no `secret-tool` and no PowerShell. The mobile vault is a fourth backend reaching the existing native `SecureStore` (Android `EncryptedSharedPreferences` over the hardware-backed Keystore, iOS Keychain) through the host bridge. `SecureStore.java`, `SecureStore.swift` and both `SecureStorePlugin` files stay: they are the keychain itself and the WebView's route to it, not engine bridges. Test the mobile backend against an in-memory host implementation, matching how `SecureStore` is already unit-tested on a plain JVM through its `Backing` interface.

19. **Port `packages/tools`:** `types`, `image`, `video`, `file_info`, `tool_verification`, `tool_downloader`. On desktop and CLI these shell out to `magick`, `identify`, `convert`, `ffmpeg` and `ffprobe`; port that verbatim with `std.process.Child`.

    On mobile a process cannot be spawned, and media goes through the existing `ImageMagickRunner`, `FfmpegKitRunner` and `MediaToolRunner`. Define a `MediaTools` vtable with a second implementation that reaches those runners through the host bridge, and test it in Zig against a stub that records the request and returns canned responses, so the marshalling is covered without a device.

## Phase 3: the API layer and the task handlers

20. **Port `packages/api`:** `constants`, `write_lock`, `database_update`, `load_assets` and its types, `save_assets.types`, `database_config`, `database_state`, `database_descriptor`, `asset`, `op`, `database_op`, `database_op_record`, `asset_query`, `replicate_database.types`, `sync_database.types`, and `lan_share/`. `packages/user-interface` imports `IAsset`, `IDatabaseOp` and `IConflictResolution` and `packages/mobile-frontend` imports one name, so those types stay TypeScript declarations. Enumerate them before starting.

21. **Port `packages/lan-share-network`,** and `importShareSecrets` from `packages/lan-share-core`. `lan_share_types`, `lan_share_receiver` and `lan_share_sender` over UDP discovery and TCP transfer, mapping onto `std.net`. `packages/lan-share-core` itself must stay: `packages/mobile-frontend` imports it.

    This is a format that crosses machines, and it is the one place a Zig implementation meets a TypeScript one in the field, because a phone and a desktop will not be upgraded on the same day. `bun run test:cli:lan-share` and `bun run test:lan-share:cli-desktop` are the suites that cover it, and both must pass. The receiver is one of the two long-lived handlers from step 5: a socket read timeout, a token checked each time round the accept loop, and the listening socket closed on cancel, with a test asserting that cancelling mid-transfer aborts rather than completes.

22. **Port `packages/task-queue`'s worker half:** `types`, `task_context`, `queue_backend`, `task_queue`, `worker`, `worker_queue_backend`. The frontend half (`TaskQueue`, `types`, `queue-backend`) is imported by `packages/user-interface` and stays TypeScript.

    `TaskHandler`'s `(data, context) => Promise<any>` becomes a blocking function over a JSON value; `registerHandler`, `getHandler` and `executeTaskHandler` keep their names. Replace the process-singleton `setQueueBackend`/`getQueueBackend` with a backend passed in explicitly, and record the divergence. Add a `ThreadPoolBackend` running handlers on a `std.Thread.Pool` with cancel-by-source and streamed messages, which is what `WorkerPoolBun`, `WorkerPoolElectronMain` and the native `EnginePool` each provide today. Cancelling a pending task drops it from the queue; cancelling a running one sets its token and lets the handler return `error.Cancelled` at its next check. Test both, plus a handler that ignores its token being reported as a cancellation timeout rather than hanging shutdown.

23. **Port the non-handler parts of `packages/node-api`:** `media_file_database` (714 lines, the centre of the API), `open_storage`, `resolve_storage_credentials`, `databases_config`, `databases_config_format`, `desktop_config`, `file_scanner`, `hash`, `hash_cache`, `hash_file`, `image`, `video`, `validation`, `tree`, `verify`, `check`, `repair`, `replicate`, `replicate_database`, `sync`, `import`, `apply_database_ops`, `encrypt`, `decrypt`, `zip_utils`, `lazy_origin_storage`, `news_fetcher`, `news_state`. `news_fetcher` uses `std.http.Client`, tested against a local `std.http.Server`. `packages/user-interface` imports exactly four names (`IDatabaseSummary`, `IGetDatabaseSummaryData`, `IMoveAssetsData`, `ISaveAssetItem`), which stay as TypeScript declarations.

    Replicate and sync are the other format crossing machines. `bun run test:cli` covers them; `psi replicate`, `psi sync` and `psi verify` are the assertions that matter.

24. **Port the task handlers,** one file each, from `packages/node-api/src/lib/*.worker.ts`. There are **nineteen handler files producing twenty-two handler names**, because `lan-share.worker.ts` exports three from one file: `verify`, `check`, `load_assets`, `upload_asset`, `prefetch_database`, `sync_database`, `replicate_database`, `save_asset`, `save_assets_batch`, `create_database`, `import_assets`, `hash_file`, `get_database_summary`, `move_assets`, `asset_server`, `lan_share`, `check_database_exists`, `list_s3_dirs`, `databases_config`.

    There are **two registration sites, not one**, and they register different sets. Port both:
    - `packages/node-api/src/lib/task-handlers.ts` registers **nineteen names from seventeen files**. It does not register `list-s3-dirs`, `read-databases-config` or `write-databases-config`, and does not import those two files at all. This is the set the CLI and the Electron main process use.
    - `packages/mobile-worker/mobile-worker-entry.ts` registers **twenty-two names from nineteen files**: the nineteen above plus those three. This is the set the mobile apps use, and it is the only place those three are registered anywhere in the repository. Losing it costs the mobile apps S3 directory listing and the databases config entirely.

    The drift test reads **both** TypeScript files and asserts each Zig registration set matches its counterpart, and additionally that the two differ by exactly those three names. If a future change moves a registration between them, the test fails and names the handler.

25. **Port the asset server:** `asset_server_core` and `asset_server_routes` from `packages/node-api`, plus `packages/rest-api/src/lib/asset-server.ts` (98 lines of Express wiring). In Zig it is `std.http.Server`, serving the same routes. HTTP parsing comes from the standard library and is not written here, which is what step 1's second amendment covers. **Do not build a request parser over raw `std.net`**; if `std.http.Server` cannot serve these routes, stop and report.

    The mobile gallery loads thumbnails through this server (see the `1-load-fixture` mobile smoke test), so its route contract is load-bearing and `bun run test:and` is the suite that proves it.

    Every route parameter arrives from a request path or query string, so validate before touching storage, with a test naming each rejected input: `id` must be a well-formed UUID; `type` must match a fixed constant list exactly; `databasePath` must resolve, after normalisation, to one of the databases the server was configured with; and any component containing `/`, `\`, `..`, a NUL or a leading `~` is rejected before normalisation, so a rejected path cannot become an accepted one by being resolved. The Express implementation does none of this today and relies on the storage layer to fail. Say plainly when this increment lands that it is a hardening the TypeScript server did not have, so the human can decide whether that was a bug worth reporting separately.

    This is also the increment that makes `packages/rest-api` empty. Delete it.

## Phase 4: retire the mobile worker

26. **Replace the embedded JavaScript engine with a direct C ABI.** By this point every package the mobile worker runs is Zig behind a host-bridge call, so QuickJS and JavaScriptCore are executing a thin layer of TypeScript whose only job is to marshal into Zig and back. This increment removes that layer.

    Export a C ABI from `zig/apps/psi-mobile/`: `psi_init`, `psi_add_task`, `psi_cancel_tasks`, `psi_shutdown`, `psi_free_string`, callback registrations for task completion and task messages, and the host callbacks for media and the vault. `psi_init` registers the mobile handler set from step 24, not the shared one.

    A C ABI with no written memory and threading contract is a use-after-free waiting to happen, and neither Java nor Swift can infer the rules. Write them in `zig/apps/psi-mobile/README.md` next to the header and encode each as a test:
    - **Inbound strings** are borrowed for the duration of the call only; the library copies anything it keeps. This is what lets Java pass a `GetStringUTFChars` pointer and release it immediately.
    - **Outbound strings** are allocated by the library and returned with `psi_free_string`. The library never frees one on its own schedule and never hands out a pointer into its own state.
    - **Encoding** is UTF-8, NUL-terminated, with no separate length. Non-ASCII paths are the normal case on a phone. Test a non-ASCII path, an emoji outside the basic multilingual plane, a combining sequence, and the two cases where Java's modified UTF-8 differs from standard UTF-8 (`U+0000` inside a string, and a surrogate pair), each round-tripping through `psi_add_task` and back out unchanged, asserted from Zig, Java and Swift.
    - **Threading:** `psi_init`, `psi_register_host` and `psi_shutdown` are single-threaded and not safe to call concurrently with anything. `psi_add_task` and `psi_cancel_tasks` are safe from any thread. Callbacks are invoked from pool threads, never the caller's, so the native side marshals to its own main thread. Host callbacks are invoked from pool threads, must be thread-safe, and must not re-enter the library.
    - **Lifecycle:** `psi_add_task` before init or after shutdown returns a named error and never crashes. `psi_shutdown` follows the step 5 contract, and every in-flight task gets its completion callback with a cancelled result so the native side never waits forever. `psi_init` after `psi_shutdown` starts a clean library, which is what an Android process that survives activity restarts needs.
    - **Errors:** no function can panic across the boundary. Every Zig error becomes a return code plus an outbound error string; a panic in a pool thread aborts loudly rather than unwinding into Java or Swift, which is undefined behaviour on both.

    Test all of it **from Zig first** with stub callbacks, so a failure names the ABI rather than the platform. The Java and Swift tests then cover only the platform half: JNI and Swift string conversion for the same values, callbacks marshalled onto the platform main thread, and the media and secure-store callbacks dispatching to the real runners and `SecureStore`.

    On Android, `QuickJsTaskEngine.java` is replaced by a `ZigTaskEngine.java` implementing the same `TaskEngine` interface, so `EnginePool` is untouched. `EngineCallbacks.java` is kept and re-pointed. `HostFunctions.java`, `HostBridge.java`, `TlsHost.java`, `TcpHost.java`, `UdpHost.java`, `CryptoHost.java` and `SecureStoreHost.java` are deleted: their only purpose was servicing `host.*` calls from an embedded JavaScript engine. `PathSandbox.java` is deleted **because `path_sandbox.zig` from step 16 replaces it**, not because the confinement stopped being wanted. `SecureStore.java`, `SecureStorePlugin.java`, `JsEnginePlugin.java`, `EnginePool.java`, `PooledTask.java`, `CancellationState.java`, `ImportPicker.java`, `ExportTemp.java`, the four media runner files and `cpp/run_magick.c` are all kept: every one has a caller that is not the JavaScript engine. iOS is the mirror image, with `JavaScriptCoreTaskEngine.swift` replaced by `ZigTaskEngine.swift` and `JsEnginePlugin.m`, `SecureStorePlugin.m` and `run_magick.h` kept alongside their Swift counterparts.

    Remove the `build:bundle` and `copy:bundle` steps from the mobile apps' `sync` scripts and add a build step that produces the Zig static library first: a Gradle task on Android, an Xcode build phase invoking `mise exec -- zig build mobile-ios` on iOS. The Xcode phase must work under Xcode 14.2.

    Then delete `packages/mobile-worker` (7,045 lines: the runtime, the host functions, `install-globals`, `install-url`, `media-commands`, and all nineteen Node shims), along with `WorkerBundleParityTests.swift` which exists to guard the bundle. `packages/mobile-frontend` and `packages/user-interface` are not modified: the new engine keeps the same `IJsEnginePlugin` contract.

27. **Retire the Electron JavaScript worker pool.** With the handlers in Zig, `apps/desktop/src/lib/worker-pool-electron-main.ts` is replaced by a backend forwarding to the addon, and `apps/desktop/src/worker.ts`, `src/rest-api-worker.ts` and `src/lib/worker-log-electron.ts` (roughly 1,300 lines together) are deleted with their `bundle:worker` script. `preload.ts` and every IPC channel name stay exactly as they are, so the renderer is untouched and no new IPC channel is added.

## Phase 5: documentation and shipping

28. **Update the six documents this port makes wrong:** `docs/development.md` (the Zig toolchain, `mise exec -- zig build`, the `zig` workspace package), `docs/testing/README.md` (`zig/run-tests.sh` and its three passes), `docs/background-tasks.md` (a handler is now Zig, and there are still two registration sites), `docs/git-hooks.md` (the `what-changed.json` additions from step 3), `docs/mobile-native-media.md` (media arrives through the host callback, not the `host.*` bridge), and the root `README.md`. Add `docs/zig-port/README.md` to the guides index in `CLAUDE.md` and `docs/development.md`.

29. **Update `THIRD-PARTY-NOTICES.md`** for everything now linked into shipped binaries: the AWS C runtime (`aws-c-s3`, `aws-c-auth`, `aws-c-http`, `aws-c-io`, `aws-c-cal`, `aws-c-compression`, `aws-c-sdkutils`, `aws-c-common`, `aws-checksums`), `s2n-tls`, OpenSSL or BoringSSL whichever step 12 chose, and libbson. Licence and pinned version for each, matching the format the existing entries use. This is a shipping requirement, not paperwork.

30. **Settle the compiled-CLI question from step 6.** If the addon can live inside a `bun build --compile` executable, nothing more is needed. If it cannot, implement whichever option step 6 recorded, and update `apps/cli`'s `upgrade` command and `apps/cli/smoke-tests-lan-share.sh`, both of which resolve paths from the `bin/<arch>/<platform>/psi` layout. Run all five CLI smoke suites with `USE_BINARY=true` as the acceptance test, since the default runs from source and would not catch this.

## Deferred, not ported

- `apps/cli/src/cmd/mcp.ts` and `apps/desktop/src/lib/mcp/` depend on `@modelcontextprotocol/sdk`, which has no Zig equivalent. They stay TypeScript, calling the Zig-backed packages like everything else.
- `apps/cli` itself, `apps/bdb-cli` and `apps/mk-cli` stay TypeScript. Because packages are replaced in place, all three run on the Zig implementations without being ported. Rewriting the CLI in Zig would mean reproducing Commander's exact help text, error wording and exit codes, which `apps/cli/smoke-tests.sh` asserts on, and it buys nothing this plan needs.
- `packages/user-interface`, `packages/desktop-frontend`, `packages/mobile-frontend`, `packages/lan-share-core` and `packages/config` are not ported. The UI stays React.

## What this removes as it goes

Unlike the parallel-tree version, removal happens inside the increments rather than being deferred to a decision at the end. Line counts are from the current tree, counting `src/**/*.ts` and `src/**/*.tsx` excluding `test/`.

| Increment | What goes | Lines |
| --- | --- | --- |
| 26 | `packages/mobile-worker` entirely: the runtime, host functions, and all nineteen Node shims | 7,045 |
| 25 | `packages/rest-api` | 98 |
| 27 | The Electron JS worker pool and its entry points | ~1,300 |
| 17 | `packages/bdb` implementation (types stay) | 13,703 |
| 23, 24 | `packages/node-api` implementation; `packages/user-interface` imports four type names, which stay | 9,283 |
| 15 | `packages/storage` implementation | 3,192 |
| 11 | `packages/merkle-tree` implementation | 2,724 |
| 18 | `packages/vault` implementation | 1,058 |
| 19 | `packages/tools` implementation | 911 |
| 9 | `packages/serialization` implementation | 836 |
| 21 | `packages/lan-share-network` implementation | 796 |
| 12 | `packages/encryption`, less what the renderer imports | 656 |
| 13 | `packages/utils` Node-side half; the browser-safe half stays | part of 891 |
| 20 | `packages/api` implementation; the types the frontends import stay | part of 1,240 |
| 10 | `packages/fuzzy-match` | 47 |
| 22 | `packages/task-queue` worker half; the frontend half stays | ~240 of 956 |

Third-party dependencies that go with them: `@aws-sdk/client-s3` and `@aws-sdk/lib-storage`, `bson`, `express`, and the mobile crypto and polyfill set pulled in only to run the AWS SDK inside a bare JavaScript engine (`browserify-aes`, `buffer`, `create-hash`, `create-hmac`, `hash.js`, `pako`, `randombytes`, `whatwg-url`). `commander` stays, because the CLI stays TypeScript.

`packages/node-utils` (1,572 lines of Node-only helpers: `exec`, `fs`, `dir`, `pipe`, `find-available-port`, termination, exit codes, test generators) is not a separate increment. Its Zig equivalents are `std.fs`, `std.process` and `std.net`, so each helper is absorbed into whichever module calls it, and the package shrinks to whatever `apps/cli` still uses directly.

## Verify

At the end of every increment, without exception:

1. `bun run compile` passes.
2. `mise exec -- zig build` completes with no errors or warnings for the host.
3. `zig/run-tests.sh` passes all three passes: `zig build test`, `zig build test -Doptimize=ReleaseSafe`, and the Valgrind pass over the C-linking modules, or prints visibly that Valgrind is absent.
4. `bun run test` passes.
5. Every smoke suite listed in the increment contract passes, with the same counts as before the increment.
6. `bun run tev -- --force` passes.
7. The TypeScript implementation the increment replaced is gone from the tree.

Additionally, once per phase:

8. `mise exec -- zig build mobile-android` and `mise exec -- zig build mobile-ios` complete for all five mobile targets (`aarch64-linux-android`, `armv7a-linux-androideabi`, `x86_64-linux-android`, `aarch64-ios`, `x86_64-ios-simulator`).
9. `mise exec -- zig build node` completes for all four desktop targets (`x86_64-linux`, `x86_64-windows`, `x86_64-macos`, `aarch64-macos`), and a packaged Electron artefact contains a loadable addon for its platform.

## Notes

- **Three things can stop this plan dead**, and all three are spiked in phase 0 for exactly that reason: the Node-API addon route for Electron and the compiled CLI (step 6), Zig linking under Xcode 14.2 (step 7), and the AWS C runtime building for Android and iOS (step 14, spiked before `storage` rather than in phase 0 because nothing before it needs S3). If any fails there is no permitted workaround inside this repository's rules, so stop and report rather than improvise.
- **Step 8 is the plan.** Everything after it is repetition of a mechanism that step 8 either proved or did not. If step 8 cannot get all four platforms green, the incremental approach does not work either, and that is worth knowing after one package rather than after fifteen.
- **`CLAUDE.md` forbids this work outright** in three separate bullets, not one. Step 1 amends all three. Amending only the language ban would leave steps 21, 25 and the standard-library HTTP decisions in violation.
- **The frozen files stay frozen.** `.githooks/pre-commit`, `scripts/install-hooks.sh` and `scripts/test-everything-parallel.sh` are not touched. The consequence is that `scripts/test-everything-parallel.sh` hardcodes its script set, so `bun run tev` picks up the Zig build and unit tests through the `zig` workspace package and the `what-changed.json` path additions in step 3, but nothing new beyond that. The smoke suites in the increment contract already exist and are already in `tev`, which is precisely why this plan uses them as its evidence rather than adding new ones.
- **Deliberate divergences from the TypeScript**, all recorded in `docs/zig-port/README.md`: async becomes blocking plus an explicit thread pool, with cooperative cancellation through an explicit token because a blocking thread cannot be interrupted from outside; interfaces become vtable structs; every allocating function threads an allocator; the queue backend stops being a process singleton; the path sandbox moves out of Java and Swift into `path_sandbox.zig`; the asset server validates its route parameters where the Express one does not; and BSON, RSA, AES-CBC and PEM come from C libraries, because Zig's standard library has no CBC mode and no RSA.
- **There is no drift problem in this plan.** The parallel-tree version needed `ported.json`, blob-hash tracking and a drift report because two implementations of every package coexisted for months. Replace-in-place has exactly one implementation of each package at any moment, so there is nothing to drift.
- **The `zig-core-port` worktree is kept for reference and will not be used again.** The abandoned attempt created a git worktree at `.claude/worktrees/zig-core-port`, on a branch of the same name, and it holds a substantial amount of work: 117 Zig source files, roughly 27,000 lines, across sixteen module directories under `zig/lib/psi-core/src/` (`api`, `bdb`, `config`, `encryption`, `fuzzy_match`, `lan_share_core`, `lan_share_network`, `merkle_tree`, `node_api`, `node_utils`, `serialization`, `storage`, `task_queue`, `tools`, `utils`, `vault`), with about 1,030 `test` blocks. It also contains seven spikes under `zig/spikes/`: `s3`, `napi`, `android`, `http`, `flate`, `crossenc` and `cloudcheck`. Alongside those it has edits to `CLAUDE.md`, `mise.toml`, `package.json` and `bun.lock`, and a `docs/zig-port/README.md`.

  Three things about it matter. **None of it is committed:** the branch has no commits beyond `mobile`, so every one of those files is staged or untracked working-tree state that an ill-judged `git checkout` or `git clean` in that worktree would destroy. **None of it is verified here:** whether it builds, whether those 1,030 test blocks pass, and how far each module actually got are unknown as of this rewrite, and nothing in this plan should be read as claiming otherwise. And **it was written against the superseded parallel-tree design**, so its structure assumes a second implementation living beside the TypeScript one, which is exactly what this plan does not do.

  It is deliberately not deleted. The right way to use it is as a reference to read: the `s3` and `napi` spikes may well answer questions that steps 6 and 14 ask, and a module already ported there is a starting point worth reading before porting the same module again. Do not work in it, do not merge it, and do not treat anything in it as current or as evidence that a package is done. All work on this plan happens in the main working copy, and a module is ported only when it has passed the increment contract above.
- **Facts established by review of the previous version of this plan**, carried forward here so they are not rediscovered: `IStorage` has seventeen methods, not twenty; the handlers are nineteen files producing twenty-two names across two registration sites, not one; `apps/smoke-tests/tests/` holds 41 tests and `apps/desktop/smoke-tests/` holds 34, and in both cases the number to match is whatever the run reports on the day; `apps/cli/smoke-tests.sh` and `smoke-tests-encrypted.sh` have separate copies of `get_cli_command()` while `smoke-tests-lan-share.sh` has none and sets `CLI_CMD` instead; `std.crypto` has no CBC mode; and `packages/mobile-worker/mobile-worker-entry.ts` is the only place in the repository that registers `list-s3-dirs`, `read-databases-config` and `write-databases-config`.
