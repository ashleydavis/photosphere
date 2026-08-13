# Port Photosphere to Zig and Vercel Native, in a new repository

## Overview

Photosphere today is sixteen TypeScript packages under `packages/` plus ten apps under `apps/`, wrapped for the desktop by Electron and for the phone by Capacitor, with background work running inside an embedded JavaScript engine (QuickJS on Android, JavaScriptCore on iOS) driven by a host bridge.

This plan replaces all of that with a **new repository** containing a Zig core, a Zig command line tool, and a single **Vercel Native** application shell that covers Windows, Linux, macOS, Android and iOS. Electron and Capacitor both go. The React user interface is carried across unchanged and is not ported: Vercel Native embeds a directory of built frontend assets and serves them to the system WebView, so the UI keeps being TypeScript and React and becomes the only TypeScript that ships.

**Bun stays.** Wherever TypeScript or a script survives into the new repository, Bun is what runs it: the workspace and its dependencies, every `package.json` script, the bundling of the React frontend, the TypeScript unit tests, and the host-side pieces of the smoke test harness. The one thing that may not be Bun's to run is the Vercel Native CLI itself, which ships on npm and states Node 22.15+ as its requirement; whether it runs under Bun is settled by the first spike and not assumed here.

The work is cut into individually testable packages of work, each with a written specification, unit tests and (where the package can be reached from outside) smoke tests. The intended way to execute it is autonomous: an orchestrator picks the next ready package, an implementation subagent builds it in its own transient worktree and commits, a review subagent checks it against the specification and runs the tests, and the two hand back and forth until the review passes. The final section of this document tells the human how to set that up and what it cannot do without them.

**Step 1 stops.** The first thing that happens in the new repository is a `CLAUDE.md`, and then nothing else until the human has read and accepted it.

### A concern worth stating before the plan starts

The previous version of this plan existed because two attempts at a big-bang Zig port failed, and its central finding was that a parallel tree produces nothing testable until roughly two thirds of the way through, which is why it ported packages in place behind the existing interfaces so that the existing smoke suites were the evidence after every increment.

A new repository throws that safety net away by construction. There is no existing application calling the new code, so the same failure is available again. The plan below answers it in a different way rather than pretending the risk is gone: the walking skeleton (a launchable window, a working control bridge and one passing smoke test) is built before any core library, the command line tool comes online early because its eighty smoke tests are headless and can run anywhere, and every work package after the skeleton has to make at least one more real test pass in a real binary. If a work package cannot state which test goes from red to green, it is the wrong package.

## What the new repository contains

This layout is the plan's proposal, not a settled fact. Step 1 writes it out in full as a document in the new repository, down to the file, and the human checks it before any of it is built.

```
docs/                     the full documentation set, written in step 1
frontend/                 the React UI, built by Bun to a dist that app.zon embeds
  packages/user-interface   carried over from the old repo, near unchanged
  packages/config           carried over if still needed by the UI
  src/platform-native.tsx   the one platform provider, over window.zero
src/                      the Vercel Native host: bridge handlers, wake/drain, servers
  main.zig
  asset_server.zig        localhost HTTP with range requests, for media bytes
  events.zig              WebSocket channel for pushed events
lib/psi-core/src/         the port of packages/, one directory per old package
apps/cli/                 the Zig command line tool (replaces apps/cli)
tests/
  unit/                   Zig test blocks live beside their source; this is the runner
  cli/                    the eighty numbered CLI smoke tests plus the five other suites
  app/                    the deduped UI smoke tests, run on every platform
  lib/                    the shared shell harness: runner, control bridge, process control
app.zon                   manifest: windows, capabilities, security, frontend
build.zig                 owned (ejected) build, because C libraries have to be linked
package.json              Bun workspace, Bun scripts, the pinned Vercel Native CLI
bunfig.toml               Bun configuration, if the workspace needs any
mise.toml                 pins Zig 0.16.0 and Bun, and Node only if the SDK CLI needs it
automation/               the work package specifications and the orchestrator state
```

What is Zig: everything that was `packages/` except the user interface, everything that was `packages/node-api`, `packages/rest-api` and `packages/mobile-worker`, the command line tool, and the application host.

What stays TypeScript: `packages/user-interface` and whatever it needs, the host-side smoke test control bridge, and the build tooling. All of it is run by Bun, and none of it is present at runtime in a shipped binary.

Bun's specific jobs, so that no part of this is left to preference:

- **The workspace.** `bun install`, workspace packages, and the lockfile, exactly as the current repository does it.
- **Every script.** `bun run compile`, `bun run test`, `bun run test:cli` and the rest, with the same naming as today so the muscle memory carries over. Shell scripts are still shell and are still invoked through their `bun run` name rather than directly.
- **Bundling the frontend.** `bun build` is the intended bundler. The current frontend is built by Vite with the React plugin, Tailwind and PostCSS, so this needs an answer for the Tailwind and PostCSS pipeline, which `bun build` does not carry. Step 2 settles it: either Bun drives Tailwind's own CLI as a separate build step, or Vite stays and Bun invokes it. Do not decide it here and do not assume `bun build` alone is enough.
- **TypeScript tests.** `bun test` for whatever unit tests the frontend keeps, replacing Jest and `ts-jest`. Zig tests stay with `zig build test`.
- **Typechecking.** `tsc --noEmit` under Bun, as now.

What disappears with no replacement: Electron, Capacitor, the embedded JavaScript engines and their host bridge, `packages/mobile-worker` and its nineteen Node shims, `packages/rest-api` and Express, the Electron worker pool, the Node-API addon route the previous plan needed, the `@aws-sdk` packages, `bson`, and the mobile crypto polyfill set that existed only to run the AWS SDK inside a bare JavaScript engine.

## Vercel Native: what it gives, what it costs

Everything here comes from the probe repository at https://github.com/ashleydavis/electron-alternative-vercel-native and its README, which is the record of what was built and run rather than what the vendor documents claim.

Three channels between the frontend and Zig, because they solve different problems:

- **The bridge**, for control flow. `await window.zero.invoke("native.command", payload)` runs a Zig handler and resolves with a JSON value. Zig pushes the other way with `runtime.emitWindowEvent(window, "name", detail)`, received by `window.zero.on`. Events carry validated JSON and escaped names, so there is no script injection surface. This replaces every Electron IPC channel and every Capacitor plugin call.
- **A localhost HTTP server**, for bytes. The bridge settles a promise with a JSON value, so images and video cannot go through it. The probe serves media from `127.0.0.1` on an OS-assigned port with range request support, and the page asks Zig for the port over the bridge because the page is on `zero://app` and is therefore cross-origin to the server. This is what the asset server becomes.
- **A WebSocket**, for a long-lived duplex channel. This is what task progress, toasts and news notifications become.

The threading rule that everything obeys: the WebView belongs to the UI thread. A worker publishes into atomics and calls `wake()`, which is a bounded non-blocking enqueue any thread may call; the loop thread then drains and emits. Nothing but the drain touches the WebView.

The costs, each of which the plan has to deal with:

- **Zig 0.16.0 exactly**, pinned by the SDK. Zig 0.16 routes sleeping and other blocking through a `std.Io` instance rather than free functions, which changes how every blocking call in the port is written.
- **A JavaScript runtime is a build-time dependency** for a Zig program, because the SDK ships as an npm CLI and states Node 22.15+ as its requirement. Bun installs it and Bun runs the scripts around it either way; the open question is whether the CLI's own code runs under Bun or needs Node underneath it. Step 2 answers it by running `native build`, `native check`, `native package` and both mobile targets under Bun. If any of them needs Node, Node is pinned in `mise.toml` for that one purpose and nothing else, and the port says so where a reader will find it.
- **Build on the target operating system.** Zig cross-compiles readily on its own, but this links against platform SDKs and system libraries, so Windows, macOS and Linux each need their own runner. The previous plan's four-target cross-build story is gone.
- **Linux needs GTK4 and WebKitGTK 6.0 development packages**, and the runtime needs `libgtk-4-1` and `libwebkitgtk-6.0-4`. Ubuntu ships the GTK3-era `libwebkit2gtk-4.1` by default, so this asks more of a user's machine than Electron does and has to be declared in whatever gets shipped.
- **Ubuntu 24.04 and friends restrict unprivileged user namespaces**, which kills WebKit's sandbox and makes the app exit at launch. The probe works around it by disabling the WebView sandbox in dev, which is not acceptable for anything shipped. The shipping answer is a decision this port has to make and record.
- **Mobile is vendor-labelled experimental and nothing has been built for a phone.** The CLI carries a real mobile toolchain (it generates an Xcode project with pbxproj, scheme, `Info.plist` and asset catalog, and drives the NDK, writes an `AndroidManifest.xml`, assembles a debug APK, boots an emulator and installs over adb), and all of that is read from the CLI rather than run. The mobile docs page is a 404.
- **The probe's own note about porting**, worth repeating because it is about this exact application: the Zig core and the bridge would come across unchanged, but the localhost HTTP server and the WebSocket both bind loopback sockets, which iOS is unfriendly about, and a fixed window size means nothing on a phone.
- **`@native-sdk/cli` went from 0.0.0 to 0.8.4 in about five weeks.** Pin the exact version, never a range, and treat an upgrade as its own work package with the full suite behind it.
- **The SDK's documentation is not a reliable specification.** Two of the three central APIs in the probe's `src/main.zig` were undocumented or documented wrongly and had to be recovered by reading `node_modules/@native-sdk/cli/src`. Budget for reading the SDK source.
- **Zero-config means no `build.zig`.** This port needs one, because it links C libraries (the AWS C runtime, OpenSSL or BoringSSL, libbson). `npx native eject` writes an owned `build.zig` and `build.zig.zon`. Whether an ejected build still gets the mobile toolchain, the asset embedding and the packaging commands is the first thing the shell spike has to answer.

## Two rules for every line of Zig in this port

These are not style preferences. They are what makes the port reviewable by a human and by a review subagent, and they belong in the new repository's `CLAUDE.md`.

### 1. The Zig emulates the TypeScript, so the two can be compared line by line

The reason this port can be trusted at all is that a reader can put the TypeScript and the Zig side by side and check them against each other. That only works if the Zig is a transliteration rather than a redesign.

- One Zig file per TypeScript file, at the same relative path, base name with `-` replaced by `_`.
- Every Zig file opens with `// Port of packages/<pkg>/src/lib/<file>.ts` naming the source in the old repository.
- Declaration order matches the TypeScript. Function names match the TypeScript. Parameter order matches the TypeScript.
- Control flow matches the TypeScript: the same branches, in the same order, with the same early returns. Do not merge two loops into one, do not hoist a condition, do not replace a loop with a cleverer formulation.
- TypeScript doc comments are ported verbatim.
- Interfaces lose the `I` prefix and become a struct with a vtable (`IStorage` becomes `Storage`), and their method names are unchanged.
- Where the Zig cannot mirror the TypeScript, the divergence gets a `// Diverges from the TypeScript:` comment at the site saying what changed and why, and an entry in the port's divergence document. The known ones are listed at the end of this plan.
- Improvements are not free. A better algorithm, a tighter data structure or a fixed bug in the middle of a port destroys the comparison for everything around it. If something in the TypeScript is wrong, port it faithfully, say so at the time, and let the human decide whether to fix it in both or in neither.

### 2. Pure and functional, with globals only at the edges

- A core library function takes what it needs as parameters and returns what it produces. No process-wide state, no lazily initialised singleton, no module-level mutable variable, no hidden cache, no ambient logger, no ambient allocator.
- `lib/psi-core/**` gets no mutable globals at all. Constants are fine. A `const` table is fine. A `var` at module scope is not, whatever it is protecting itself with.
- State that has to exist lives in a struct the caller owns and passes in, so two of them can exist at once and a test can make one.
- Effects are parameters: the allocator, the clock, the UUID source, the filesystem, the network and the process spawner all arrive as vtable structs, which is also what makes the deterministic test implementations the smoke tests rely on possible.
- Globals are tolerated only at the edges: `src/main.zig` and the platform host it talks to, the CLI entry point, and the process-level runtime the SDK owns. Even there, the global is a container that is constructed once at startup and passed down, never reached back up into.
- The old `setQueueBackend`/`getQueueBackend` process singleton is the exact pattern this rule exists to stop. It does not come across.

## Phase 0: the rules and documentation checkpoint

**1. Create the new repository, write its `CLAUDE.md` and its entire documentation set, and then stop and wait.**

No code, no build files, no manifest, no toolchain pin. Words only. Nothing else is written until the human has read all of it and said it is acceptable, and the rest of the plan does not start while it is outstanding. This is the cheapest place in the whole port to find out that the structure or the rules are wrong, and the most expensive thing to change once forty work packages have been built on top of it.

**The project map is the centrepiece.** `docs/project-structure.md` is a tree of the repository as it will exist when the port is finished: every directory, every significant file, and one line each saying what it holds and why it is there. It covers the Zig core module by module, the application host, the CLI, the frontend, all four test trees, the build and manifest files, and the automation directory. Where a directory corresponds to something in the old repository, the line names it, so the map doubles as the porting index. The current repository has no document like this, which is part of why this one starts with it.

The rest of the set, all written in step 1 and all reviewed together:

- `README.md`: what the project is, what it runs on, and how to build and run it.
- `docs/development.md`: the day to day loop, the toolchain, the Bun scripts, and an index of every other document.
- `docs/testing/README.md`: the four kinds of test (Zig unit, TypeScript unit, CLI smoke, application smoke), how to run each, how the harness allocates ports and directories, and what parallel safety requires of a new test.
- `docs/architecture.md`: the three channels between the frontend and Zig, the threading rule, where state lives, and how a request travels from a click to storage and back.
- `docs/background-tasks.md`: what a task handler is now, the single registration site, and how to add one.
- `docs/zig-conventions.md`: the two writing rules in full, with worked examples of a TypeScript file and its Zig counterpart side by side, and the divergence document's format.
- `docs/porting.md`: the map from old package to new module, the work package contract, and the implementation and review loop.
- `docs/building-and-packaging.md`: per platform requirements, the system libraries, packaging, and the release layout.
- `docs/mobile.md`: the Android and iOS toolchains, what the SDK generates, and the pinned Apple environment.
- `docs/git-hooks.md`: what the hook runs and why it is never bypassed.
- `THIRD-PARTY-NOTICES.md`: started now with the SDK and the C libraries, extended as each lands.

Documents written before the code they describe will contain claims that turn out to be wrong. That is acceptable and expected: they are a specification at this point, and each work package that contradicts one has to correct it as part of its own review. What is not acceptable is a document that describes something as working when nobody has run it, so every claim about behaviour in the step 1 set is written as intent rather than as fact, and the spikes in phase 1 are what convert them.

**The `CLAUDE.md`** starts from the existing one in this repository. Keep everything that is about how the human works and what they will not tolerate, drop everything that is about Electron, Capacitor and the embedded JavaScript engines, and add what Zig and Vercel Native need. It has to cover at least:

- **Platforms and apps.** One application shell across Windows, Linux, macOS, Android and iOS, plus a command line tool on the three desktop platforms.
- **Languages.** Zig, TypeScript (frontend and host-side test harness only) and shell script. Nothing else, with the same explicit ban on Python, Perl, Ruby and Go, and the same rule that a shell script contains shell and never an embedded interpreter.
- **Bun.** Bun runs the workspace, every script, the frontend bundle, the TypeScript tests and the typecheck. Never a bare `bun`, `node` or `zig`: every invocation goes through `mise exec --` so the pinned versions are the ones that run. Never invoke a shell script directly when it has a `bun run` name. If the Vercel Native CLI turns out to need Node, that is the only thing Node is for and the rule says so by name.
- **The two writing rules above**, in full, because they are the two things a review subagent checks that nothing else can check for it.
- **The testing rules**, carried over unchanged in substance: never a fake test, never a test that has not been watched fail, never make a test pass by faking the thing under test, run every test you write, and never report a compile as evidence of behaviour.
- **The parallel-safety rules**, carried over unchanged: no fixed port, no fixed path, no machine-wide name, every started process's pid recorded at the moment it starts, never kill by matching a command line, and every suite has to survive running beside another copy of itself. The human runs several worktrees at once and the orchestrator in this plan runs several agents at once, so this matters more here than it did before.
- **The git rules**, carried over unchanged: no destructive git without an explicit instruction, never commit with verification disabled, never modify the hook or its scripts, and never assume the working tree is as you left it.
- **Zig specifics**: `mise exec -- zig ...` for every invocation, every allocating function takes `allocator: std.mem.Allocator` first, `std.testing.allocator` in every test so a leak fails it, a `std.testing.checkAllAllocationFailures` test for anything that can fail to allocate, `ReleaseSafe` as a second test pass, Valgrind as a third where C libraries are linked, and errors as error sets rather than exceptions.
- **The failure rules**, carried over unchanged: all failures noisy, no stub that pretends to work, no silent no-op, and a missing capability throws and names itself.
- **The library rules**, carried over and adjusted: no hand-written wire protocol, request signing or vendor SDK, with the Zig standard library counted as a maintained library for what ships in it (`std.http`, `std.crypto`, `std.net`, `std.compress`) and anything outside it requiring a real vendor library.
- **The autonomy contract**: what a work package is, what an implementation agent may and may not do, what a review agent checks, and the escalation rule when they cannot agree.
- **Documentation and comment rules**, carried over unchanged, including the ban on em dashes, on `---` separators, on hard-wrapped prose, on the words this repository bans, and on machine-specific absolute paths in anything checked in.

## Phase 1: the spikes that can stop this plan dead

Each of these can end the port. All four are cheap relative to the port and all four run before any core library is written. If one fails there is no permitted workaround, so stop and report.

**2. SPIKE: the desktop shell, ejected, on all three desktop platforms.** Stand up a minimal app: one window, one bridge command, one emitted event, one localhost HTTP route with a range request, one WebSocket. Then run `npx native eject` and prove the whole of that still builds and runs from the owned `build.zig`, because the port cannot use the zero-config path once it links C libraries. Prove it builds and runs on Linux (GTK4 and WebKitGTK 6.0), on Windows (WebView2) and on macOS. Record the exact SDK version, the exact Zig version, and the system packages each platform needs.

Four things this spike must settle and write down:

- **Whether the SDK CLI runs under Bun**, across `native build`, `native check`, `native package` and both mobile targets. If it needs Node, say which commands and pin Node for that alone.
- **How the frontend is bundled by Bun**, given Tailwind and PostCSS. Either `bun build` plus Tailwind's own CLI as a separate Bun-driven step, or Vite invoked by Bun. Build the real UI, not a placeholder page, because a page with no Tailwind in it proves nothing.
- **How the frontend gets a fast development loop**: a watched build writing into the embedded dist, or an allowed development origin in `app.zon`'s navigation policy, and what the second does to the security model.
- **What the shipping answer is for the WebKit sandbox** on distributions that restrict unprivileged user namespaces, given that disabling it is not shippable.

**3. SPIKE: iOS under the pinned Apple toolchain.** The local Apple environment is macOS 12.7.6 and Xcode 14.2, and that is the reason the current repository is stuck on Capacitor 5. Vercel Native generates an Xcode project and expects `xcodebuild -scheme <app> archive` to work with no hand edits. Whether the generated project builds under Xcode 14.2 is unknown, and nothing in the probe repository has ever been built for a phone.

The spike passes when the minimal app from step 2 builds, installs and launches on the iOS simulator from the pinned toolchain, its bridge command returns a value, and its emitted event reaches the page. If loopback sockets are refused or restricted on iOS, that is part of the finding, because the asset server depends on them.

If it fails under Xcode 14.2, the options are all the human's: raise the Apple toolchain requirement and lose local iOS development on the current Mac, get a newer Mac, or drop iOS from the port. Do not pick one. Report what failed, with the exact error, and wait.

**4. SPIKE: Android through the SDK's own toolchain.** Build the same minimal app for Android through `native dev --target android`, install it on an emulator from the existing pool, and prove the same three things (bridge, event, loopback socket). The existing pool and its monitor belong to the human; use them as they are and do not start, stop or repair anything the repository's rules reserve to them.

**5. SPIKE: the C libraries, on every target.** The port needs the AWS C runtime for S3 (`aws-c-s3` and its stack, plus `s2n-tls` on Linux and Android and the Apple TLS stack on macOS and iOS), OpenSSL or BoringSSL for AES-CBC, RSA and PEM (Zig's standard library has no CBC mode and no RSA), and libbson for BSON. Prove all three build and link into the ejected build from step 2, for Linux, Windows, macOS, both iOS targets and all three Android ABIs.

Pin every C dependency in `build.zig.zon` by exact tag and content hash, never a branch or a floating reference, so a swapped upstream artefact fails a hash check rather than being fetched silently. Record each library's pinned version, repository and licence, and a named check to run against the upstream advisory feeds before each release. This stack links into every shipped binary on every platform.

## Phase 2: the walking skeleton

**6. The repository skeleton and the toolchain.** `mise.toml` pinning Zig 0.16.0 and Bun (and Node only if step 2 found it necessary), `build.zig` from the step 2 eject, `app.zon`, the Bun workspace with `@native-sdk/cli` pinned to an exact version, the frontend directory with the carried-over React UI building to a dist through whichever bundler step 2 settled on, and a `tests/` tree. One Bun script builds everything, one runs every Zig test in all three passes, one runs the TypeScript tests, and one runs a named smoke suite. The script names match the current repository's wherever the thing they do is the same.

This is also the step that reconciles the repository against `docs/project-structure.md` from step 1. Where the skeleton has to differ from the map, the map is corrected in the same commit and the difference is called out, so the document the human approved does not quietly stop being true on the first day.

**7. The test harness, ported before the thing it tests.** Bring across `apps/smoke-tests/lib/runner.sh`, the control bridge, the process control library and the temp directory allocator, because they already solve the hard parts (per-test temporary directories, OS-assigned ports, recorded pids, process group cleanup, timeouts, parallel safety) and because both the desktop and the mobile suites in the current repository already drive the application through the same control bridge and the same shared test driver inside the UI. That is what makes the deduplication in step 9 possible rather than aspirational.

**8. The walking skeleton, end to end.** The real application shell: the real React UI, loaded from the embedded dist, talking to a real Zig host over the bridge, with the control bridge attached in test mode. One smoke test launches it, waits for ready, navigates, and asserts the page reached a known state, on Linux, Android and iOS.

Nothing else starts until this passes on all three. It is the equivalent of the previous plan's step 8 and it carries the same instruction: if it cannot get every platform green, the approach does not work, and that is worth knowing now rather than after fifteen packages.

**9. Fix the smoke test parity target.** The current repository has 34 UI smoke tests under `apps/desktop/smoke-tests/` and 43 under `apps/smoke-tests/tests/`. By name they share 27, with 7 desktop-only and 16 mobile-only, so the deduplicated union is 50. That number is arithmetic on directory names and is the starting point, not the answer: go through them pair by pair, confirm that a shared name is genuinely the same test rather than two different tests that happen to be numbered alike, and produce a written list of the deduplicated suite with, for each test, which platforms it runs on and why any platform is excluded. The command line suites do not dedupe: the eighty numbered tests plus the encrypted, LAN share, hash cache, sync and write lock suites all come across as they are.

## Phase 3: the port, as work packages

Everything from here is a work package. The list below is the division of the work; the contract that governs each one is in the next section. Dependencies are on package numbers, and the orchestrator runs a package only when its dependencies have merged.

Ordering is bottom-up through the library graph, with the command line tool brought online as early as its dependencies allow, because the CLI suites are headless, cheap, run anywhere including a container with no display, and are therefore the evidence engine for the autonomous loop.

| # | Work package | Depends on | Evidence it must produce |
| --- | --- | --- | --- |
| 10 | `utils`: sleep, retry, try/swallow, uuid and timestamp vtables, logging, format, batch generator, wrapped and fatal errors | 6 | Ported unit tests; deterministic uuid and clock implementations the suites need |
| 11 | `serialization`: the binary and compressed serialisers and deserialisers, then save/load/verify | 10 | Ported unit tests; byte-identical output against fixtures written by the TypeScript |
| 12 | `fuzzy-match` | 10 | Ported unit tests, value for value |
| 13 | `merkle-tree`: tree, diff, visualise, compare, traverse, buffer map and set | 10, 11 | Ported unit tests; root hashes matching the TypeScript on the checked-in fixtures |
| 14 | `encryption`: constants, types, buffer and stream encryption, key utilities, over OpenSSL or BoringSSL | 5, 10 | Ported unit tests; a file encrypted by the TypeScript decrypting, and the reverse |
| 15 | `storage` local half: the vtable, file storage, directory walk, prefix wrapper, factory, mock storage, encryption header reader, and the path sandbox ported from the Java and Swift | 10, 14 | Full vtable tests; factory descriptor parsing case by case; sandbox escape cases |
| 16 | `storage` cloud half: cloud storage over the AWS C runtime, S3 paths, ranged reads, encrypted storage | 5, 15 | Tests against the local S3 emulator: multipart interrupted and retried, cancellation, ranged reads at and past end of file, distinct named errors |
| 17 | `bdb` BSON conformance: the per-type comparison against what the `bson` npm package writes, before any collection code | 5, 10 | A conformance test per type, each naming the type on failure |
| 18 | `bdb` records: shard, merge records, update fields, update metadata, merkle tree and its reference | 17 | Ported unit tests |
| 19 | `bdb` collection and index: collection, sort index, database, mocks | 18 | Ported unit tests; a database written by the TypeScript reading back record for record and index for index |
| 20 | `vault`: plaintext, macOS, Linux and Windows keychains, selection, plus the mobile secure store backend | 10, 15 | Selection tests per platform; the Windows PowerShell escaping tested against every hostile input; a real round trip on each platform |
| 21 | `tools`: image, video, file info, verification, download, over the external binaries; and the mobile path over the native runners | 10, 15 | Tests against real fixture media; the mobile path tested against a recording stub |
| 22 | `api`: constants, write lock, database update, load and save assets, config, state, descriptor, asset, ops, queries | 10, 11 | Ported unit tests |
| 23 | `task-queue`: types, context, backend vtable, queue, worker, and a thread pool backend with cooperative cancellation | 10 | Cancellation of pending and running tasks; a handler that ignores its token reported as a timeout rather than hanging shutdown |
| 24 | `node-api` core: media file database, storage opening, credential resolution, databases config and its format, desktop config, file scanner, hashing and the hash cache | 16, 19, 20, 22 | Ported unit tests; the hash cache concurrency suite |
| 25 | CLI part one: create, add, list, view, summary, export, verify | 24 | CLI smoke tests 01 to 16 pass |
| 26 | `node-api` operations: tree, verify, check, repair, replicate, sync, import, apply ops, encrypt, decrypt, zip, lazy origin storage | 24 | Ported unit tests |
| 27 | CLI part two: replicate, compare, repair, the version upgrade paths | 26 | CLI smoke tests 17 to 34 pass |
| 28 | CLI part three: sync | 26 | CLI smoke tests 35 to 43 pass, plus the sync suite |
| 29 | CLI part four: databases config, vault and secrets commands | 20, 24 | CLI smoke tests 44 to 64 pass, plus the keychain suite |
| 30 | CLI part five: the S3 command paths | 16, 26 | CLI smoke tests 65 to 77 pass |
| 31 | `lan-share-network`: types, receiver and sender over UDP discovery and TCP transfer, and secret import | 22, 23 | The CLI LAN share suite passes; cancelling mid transfer aborts rather than completes |
| 32 | CLI part six: share and receive, cancellation, asset metadata | 31 | CLI smoke tests 78 to 80 pass; the write lock suite passes |
| 33 | The task handlers: nineteen files producing the full handler set, and one registration site instead of the current two | 23, 24, 26, 31 | A registration test asserting the set, so a lost handler names itself |
| 34 | The asset server over `std.http.Server`, with route parameter validation, wired to the shell's localhost server | 8, 24 | Range requests, rejected inputs case by case, and a real thumbnail served to the WebView |
| 35 | The news fetcher over `std.http.Client`, tested against a local `std.http.Server` | 10 | No test reaches the network |
| 36 | The frontend platform provider over `window.zero`, replacing the Electron and Capacitor providers, plus the event channel over the WebSocket | 8, 33 | The UI reaches every host capability it used to reach through IPC or a Capacitor plugin |
| 37 to 45 | The deduplicated UI smoke suite, in groups of five or six tests, each group a work package | 36, and whichever handlers the group needs | Each group passes on Linux, Android and iOS |
| 46 | Packaging: `native package` for each platform, the release layout, and the upgrade path the CLI depends on | all | A packaged artefact installs and runs on each platform |
| 47 | Documentation reconciliation: every document from step 1 checked against what was built, the project map updated to the tree as it exists, and third party notices completed with every linked C library and its licence | all | The project map matches the repository file for file; no document describes intent that was never built |

Not ported, for the same reasons as before: the Model Context Protocol integration, which has no Zig equivalent and stays TypeScript in whatever form the shell can host, and the React UI itself.

## The work package contract

Every package of work handed to a subagent is a written specification, checked into `automation/packages/<id>.md` in the new repository, and it contains all of:

- **Goal**, in one paragraph: what exists after this and did not exist before.
- **Source of truth**: the exact list of files in the old repository being ported, by path, with their line counts. The implementation agent reads all of them.
- **Files to create**, by path, in the new repository.
- **Public interface**: the functions, structs and vtables this package exposes, with their signatures, so the next package can be specified before this one is written.
- **Divergences allowed**: the specific places this package may depart from the TypeScript, with the reason. Anything not listed here is a divergence that has to be raised, not taken.
- **Unit tests required**: named cases, not a count. Where the old repository has a Jest suite, the requirement is that suite ported case for case, plus the allocation-failure and leak coverage the TypeScript never needed.
- **Smoke evidence required**: which smoke tests go from red to green, by name. A package with no smoke evidence says so and says why (a pure library with no external surface is the only acceptable reason).
- **Dependencies**: the package numbers that must have merged first.
- **Done when**: the exact commands that must pass, and on which platforms.

A package that cannot be written down in this form is too big and gets split before anyone starts on it.

## The implementation and review loop

One cycle per work package. The orchestrator owns the loop; the two agents never talk to each other except through the worktree and the notes file.

1. **Orchestrator** picks the next package whose dependencies have merged, creates a branch and a transient worktree for it, and starts an implementation agent with the specification.
2. **Implementation agent** works only inside its worktree. It reads the named source files in the old repository, writes the Zig, writes the tests, runs them, and iterates until they pass. It commits on its branch with the verification hook enabled, always. It writes a handover note saying what it built, what it ran, what passed, and anything it could not do and why.
3. **Review agent** starts fresh in the same worktree with the same specification and the implementation agent's note. It does not trust the note. It checks:
   - Every file the specification named exists, and nothing beyond the specification was changed.
   - The Zig mirrors the TypeScript file for file and function for function, and every divergence is either listed in the specification or commented and raised.
   - No mutable global anywhere in `lib/psi-core/**`, and no hidden state in a core library.
   - Every named unit test case exists and asserts something that would fail if the code were wrong. It picks at least two, breaks the code, and confirms they go red.
   - It runs the tests itself: all three Zig passes, the unit suite, and every smoke suite the specification named, on the platforms the specification named.
   - The repository rules are met: comment blocks on globals and fields, no banned words, no absolute paths, no test-only scaffolding in application code, no stub that pretends to work.
   - The documentation still matches. Any document from step 1 that this package contradicts has been corrected in the same commits, `docs/project-structure.md` included. A package that changes the tree without changing the map fails review.
4. **If the review fails**, it writes numbered, specific findings to `review-notes.md` in the worktree, each naming a file and a line and what has to change, and hands back. The implementation agent fixes and commits again. Repeat.
5. **After three failed rounds** the orchestrator stops that package, leaves the worktree in place, and escalates to the human with the notes from every round. Three rounds of the same disagreement means the specification is wrong, not the code.
6. **When the review passes**, the orchestrator merges the branch into the main branch, runs the full suite on the main branch, removes the worktree, marks the package done in the state file, and moves on. If the full suite fails after a merge that passed in its worktree, the package goes back with that failure as its finding, because it means the package interacts with something it did not declare.

Two packages may run at once only when their dependencies are satisfied and the file sets their specifications declare are disjoint. Merges are always serialised, one at a time, on the main branch.

## What "complete" means

Parity is not a judgement call. The port is complete when all of these are true at once, on a single revision of the main branch:

- Every unit test from the old repository has a counterpart, and they all pass. The old repository has 164 unit test files across `packages/` and `apps/`; each one is accounted for as ported, superseded by a named Zig test, or written off with a reason.
- All eighty numbered CLI smoke tests pass, plus the encrypted, LAN share, hash cache, sync, write lock and keychain suites.
- The deduplicated UI smoke suite passes on Linux, Windows, macOS, Android and iOS. Where a test cannot run on a platform, the exclusion is written down with its reason and the human has accepted it.
- The CLI to application LAN share suite passes, replacing the current CLI to desktop one.
- A packaged artefact for each platform installs and launches, and the walking skeleton test passes against the packaged build rather than only against the development build.
- No TypeScript remains outside the frontend and the test harness, and every script, bundle, typecheck and TypeScript test runs under Bun.
- The documentation describes the new application, `docs/project-structure.md` matches the repository file for file, and the third party notices list every C library linked into a shipped binary with its licence and pinned version.

## How to run this autonomously

This section is for the human. It is the setup, not part of the port.

### The three lanes, and why there have to be three

The work divides by what a machine can verify, and no single machine can verify all of it:

- **The headless lane**: Zig compilation, all three test passes, every unit test, and all of the CLI smoke suites. Needs Linux, a toolchain, and the local S3 emulator. No display, no GPU, no virtualisation. This is most of the port by volume and all of packages 10 to 33.
- **The desktop application lane**: the UI smoke suite on a desktop. Needs GTK4 and WebKitGTK 6.0 and a display, which `xvfb` provides on Linux exactly as it does for the current Electron suite. Windows and macOS need their own runners, because the SDK links platform libraries and is built on the target operating system.
- **The device lane**: Android and iOS. Android needs a real emulator, which needs KVM. iOS needs macOS and Xcode, and the pinned Apple environment is a specific machine.

### Where to run each lane

**Remote Claude sessions first, if they are available to this account.** Claude Code can run agents in a cloud environment, and the headless lane is exactly what that environment suits: a container, a toolchain, no display, no devices. Check availability before planning around it, and check two things about the environment specifically: whether it can reach the network to fetch the pinned Zig, the SDK and the C dependencies, and whether the repository can be pushed and pulled from it. If both hold, the headless lane runs there and costs no hardware.

**A DigitalOcean droplet as the fallback, and as the always-on orchestrator either way.** A plain Linux droplet runs the headless lane without difficulty. Before committing to it for the device lane, run `ls -l /dev/kvm` on the droplet: without it, an Android emulator falls back to software translation and is slow enough to be useless for a suite this size. If it is absent, either take a provider that exposes nested virtualisation, or keep Android on the existing local emulator pool. Do not plan around the droplet having KVM until that command has been run and its output read.

Recommended arrangement: the orchestrator runs continuously on the droplet, drives the headless lane itself, and queues platform-restricted packages for the other two lanes. The Android emulator pool stays on the local machine where it already works and is already monitored. iOS stays on the pinned Mac. The desktop application lane runs on the droplet for Linux under `xvfb`, and on the Mac and on a Windows runner for the other two.

The consequence, stated up front: **the autonomous system converges to "everything green except the device lanes", and it cannot finish without the human's machines being reachable.** Full parity requires runs on Apple and Android hardware, and no amount of remote compute substitutes for them.

### Setting it up

1. **Create the new repository** and push an empty main branch. Decide its name. The port branches off it and never touches this repository.
2. **Run step 1 by hand**: start a session, have it write `CLAUDE.md` and the whole documentation set, read them, and accept or change them. Read `docs/project-structure.md` first and hardest, because every work package is specified against it. Nothing else starts until this is done. The autonomous system inherits whatever is in these files, so this is the highest-leverage reading in the plan.
3. **Run the four spikes** with a human watching. They are the four ways this plan dies, and each one ends in a decision that is yours, not an agent's.
4. **Provision the runners**: the droplet or the cloud sessions for the headless lane, with mise, the Zig and Bun versions the spikes pinned (plus Node if step 2 found the SDK CLI needs it), the GTK4 and WebKitGTK 6.0 development packages, `xvfb`, the C library build dependencies, and the S3 emulator. Confirm the pinned toolchain installs from a clean machine and write down the exact commands, because that list is also what a new developer needs.
5. **Write the work package specifications** for at least packages 10 to 20 before starting the loop. The loop consumes specifications faster than it produces them, and an agent writing its own specification is an agent marking its own homework.
6. **Set up the orchestrator.** Two ways, and the second is the fallback for the first:
   - A slash command in the new repository (`/port:next`) that performs exactly one cycle of the loop above and exits, driven on a schedule so that each tick picks up wherever the last one stopped. Scheduling can be a cron entry created from inside a session or a plain system cron calling headless mode.
   - A shell script on the droplet in a loop, calling Claude Code in headless mode with the same command, one cycle per invocation, sleeping between cycles.
   Either way the unit of work is one cycle, not one package and never the whole port, so a crashed or killed process loses one cycle.
7. **Keep the state outside the agent.** `automation/state/packages.json` in the repository holds, per package: status (ready, in progress, in review, blocked, merged), the branch, the worktree path, the round count and the last finding. The orchestrator reads it at the start of a cycle and writes it at the end. An agent's memory of what it was doing does not survive a restart; a file does.
8. **Set the escalation path.** Three failed review rounds, a failed merge, a red suite on the main branch, or any spike-level failure stops that package and notifies you. A push notification or a message to a session you watch is enough. Everything else keeps running.
9. **Set the limits before starting, not after.** A token or spend ceiling per cycle and per day, a maximum number of concurrent packages (two or three, because merges serialise anyway), and a stop file that the orchestrator checks at the top of every cycle so you can halt the whole thing without killing a process mid-commit.
10. **Review the merge stream daily, not the code.** The review agent reads the code; you read what merged, which tests moved from red to green, and every escalation. If the same finding keeps appearing across packages, that is a `CLAUDE.md` amendment, not a per-package fix.

### What the autonomous system must never be allowed to do

- Commit with the verification hook disabled, in any form, for any reason.
- Modify the hook or the scripts it calls.
- Force push, rewrite history, or delete a branch that has not merged.
- Touch this repository. It reads from it and writes only to the new one.
- Start, stop or repair the Android emulator pool beyond the repair commands the current repository already allows an agent to run.
- Mark a package done on the strength of a report rather than a run. The review agent runs the tests itself, and the orchestrator runs the full suite after the merge.
- Skip, disable or weaken a test to make a package pass. A failing test that cannot be fixed is an escalation.

## Risks, in the order they can bite

1. **iOS under Xcode 14.2** (step 3). The generated Xcode project is the newest, least documented part of the SDK and the pinned Apple toolchain is three years older than it. This is the most likely single point of failure in the plan.
2. **The SDK's mobile support being experimental in the vendor's own words**, with a 404 for its documentation and nothing in the probe ever built for a phone. Steps 3 and 4 are the only evidence that will exist.
3. **The C libraries on mobile targets** (step 5). The AWS C runtime failing to build for Android or iOS has no permitted workaround.
4. **An SDK moving from 0.0.0 to 0.8.4 in five weeks** under a port that will take months. Pin exactly, upgrade deliberately, and expect breaking changes.
5. **WebKitGTK 6.0 not being on users' machines.** This is a shipping problem rather than a development one, and it needs an answer before the first release rather than after.
6. **The comparison rule decaying.** The line-by-line correspondence is what makes the port reviewable, and it degrades one small improvement at a time. The review agent checking it on every package is the only thing that holds it.

## Notes

- **Facts about the old repository, carried forward so they are not rediscovered**: `IStorage` has seventeen methods; the task handlers are nineteen files producing twenty-two names across two registration sites (`packages/node-api/src/lib/task-handlers.ts` registers nineteen, and `packages/mobile-worker/mobile-worker-entry.ts` registers those plus `list-s3-dirs`, `read-databases-config` and `write-databases-config`, and is the only place in the repository that registers those three); `apps/desktop/smoke-tests/` holds 34 tests and `apps/smoke-tests/tests/` holds 43, sharing 27 names for a union of 50; `apps/cli/smoke-tests/` holds 80 numbered tests; there are 164 unit test files under `packages/` and `apps/`; `std.crypto` has no CBC mode and no RSA; and both the desktop and mobile suites already drive the application through the same control bridge and the same shared test driver in `packages/user-interface`, which is what makes one deduplicated UI suite possible.
- **The two registration sites become one.** One application, one handler set, and a test that asserts it, so a handler cannot be lost silently the way the mobile-only three could be today.
- **Known divergences from the TypeScript**, to be recorded in the port's divergence document as they land: `async` becomes blocking plus an explicit thread pool, with cooperative cancellation through an explicit token because a blocking thread cannot be interrupted from outside; interfaces become vtable structs; every allocating function threads an allocator; the queue backend stops being a process singleton and is passed explicitly; the path sandbox moves out of Java and Swift into Zig; the asset server validates its route parameters where the Express one does not; BSON, RSA, AES-CBC and PEM come from C libraries; every Electron IPC channel and every Capacitor plugin call becomes a bridge command; and Zig 0.16 routes blocking calls through a `std.Io` instance.
- **The macOS keychain exposure comes across unchanged.** The current code passes the secret as an argument to `security add-generic-password -w <json>`, and process arguments are readable by other processes. Port it as it is so existing installations can still read their secrets back, record it, and raise it with the human when that package lands. Do not fix it in passing.
- **The abandoned worktree in this repository is reference material and nothing more.** `.claude/worktrees/zig-core-port` holds roughly 27,000 lines of Zig across sixteen module directories with about 1,030 test blocks, plus seven spikes. None of it is committed, none of it has been verified to build or pass, and it was written against a superseded design that assumed a parallel tree beside the TypeScript. Read it before porting a module it already covers, particularly the `s3` and `napi` spikes, and treat nothing in it as done. Do not work in it and do not merge it.
- **This plan is transient.** Nothing that outlives the port may reference it. Anything in here worth keeping (the writing rules, the divergence list, the toolchain versions, the packaging steps) gets copied into the new repository's own permanent documents, in full, at the point it is needed.
