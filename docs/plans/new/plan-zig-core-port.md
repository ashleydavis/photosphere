# Port Photosphere to Zig and Vercel Native, in a new repository

## Goals

What this port is for. Everything else in this document exists to serve one of these, and anything that serves none of them is out of scope.

- **Port Photosphere's core from TypeScript to Zig**, every package except the user interface.
- **Replace Electron and Capacitor with Vercel Native**: one application shell covering Windows, Linux, macOS, Android and iOS, with no bundled browser engine and no embedded JavaScript engine.
- **Keep the React user interface**, carried across and embedded rather than rewritten.
- **Reach parity with the old repository**: the same features, the same unit tests, the same smoke tests, on every platform. Parity is the definition of done, and it is measured against the old repository rather than judged.
- **Write Zig that mirrors the TypeScript** file for file and function for function, so the two can be read side by side and checked against each other.
- **Make every line of new Zig deterministic**: same inputs, same outputs, every time, on every platform, at any concurrency. Pure where possible, every effect passed in, no globals. This outranks mirroring the TypeScript when the two conflict.
- **Zero flaky tests, from the first commit.** Every test proven to run beside another copy of itself and beside every other suite, because the port runs many agents at once and flakiness would poison every result they produce.
- **Never lose what the old repository knows.** Its operational scripts, its test harnesses, its emulator pool machinery, its release workflow and its hard-won rules all come across.
- **Run autonomously from beginning to end.** The system plans, implements, reviews, merges and recovers by itself, stopping only at two checkpoints, and resuming from where it left off after any crash, outage or interruption.
- **Never get blocked.** Nothing waits on a person, nothing is parked, and a package that fails comes back having changed its approach. Everything in the old repository is proof that every part of this can be done.
- **Make progress visible without asking.** Everything is committed and pushed as it happens, and one page says where the port stands.
- **Record everything as it happens**: what was done, what failed, what was decided and what was reversed, in enough detail to write the story afterwards without reconstructing anything from memory.

## Glossary

The words this document uses in a particular way. Anything not here is used in its ordinary sense.

- **Port orchestrator**, or just **the orchestrator**: the one process that drives everything. It picks work, spawns agents, runs merge trains, updates the summary and recovers whatever broke. There is one at a time, on one machine.
- **Turn**: one unit of the orchestrator's work. It reads the queues, does what is next, records it, pushes, and ends. The port is many turns; a crash costs one.
- **Agent**, **subagent**: a Claude session doing one job, spawned by the orchestrator. Four kinds: plan author, implementer, reviewer, merge train.
- **Package**, or **work package**: one plan's worth of work, roughly one old package or one clearly separable half of one. The unit that moves through the queues and gets merged.
- **Plan**: the written specification for one package, created and checked with the plan commands in `.claude/commands/port/`. Lives with the package.
- **Queue**: a directory a package sits in. The queue it is in **is** its status: `todo`, `in-progress`, `review`, `merge-queue`, `done`, plus `conflicts`.
- **Merge train**: the single-threaded process that merges reviewed packages into main. One worktree, packages merged one at a time, whole suite run, bisect on failure. Only one runs at once.
- **Findings**: what a review writes when it rejects work. One file per review pass, read by the next implementer.
- **Escalation ladder**: what happens to a package that keeps failing. Retry, then fix the findings, then re-plan, then split, then read how the old repository did it, then change route. Nothing is ever parked.
- **Parity**: the definition of done. The new repository has the same features, tests and documentation as the old one, measured against it rather than judged.
- **The comparison**: the five-part check a review makes against the TypeScript: behaviour, code, unit tests, smoke tests, documentation.
- **Meta repository**: `psi-zig-port-orchestrator`, which holds the process. Distinct from `photosphere-old` (read-only source of truth) and `photosphere-zig` (the port).
- **Prototype**: a throwaway experiment answering one question, built outside this plan and delivered to it as a finding. Referred to as P1 to P10.
- **Runner**: a machine that builds or tests, almost always a GitHub-hosted one driven by the release workflow. Not the orchestrator.
- **Flake**: a test that sometimes fails without the code changing. Treated as an emergency, never as bad luck.
- **Stuck**: an agent still running but making no progress. Killed and resumed from its last checkpoint, without diagnosis.
- **Interruption**: the run being cut off from outside, by a rate limit, a crash or a kill. Never a failure, recorded nowhere, costs one step.
- **Agent record**: the file an agent writes saying what it is, what package and pass it is on, which step it has reached, and how to resume it. What makes a crash survivable.
- **Evidence**: captured output proving a check ran and what it said. One directory per pass, never carried forward between passes.

## Overview

Photosphere today is sixteen TypeScript packages under `packages/` plus ten apps under `apps/`, wrapped for the desktop by Electron and for the phone by Capacitor, with background work running inside an embedded JavaScript engine (QuickJS on Android, JavaScriptCore on iOS) driven by a host bridge.

This plan replaces all of that with a **new repository** containing a Zig core, a Zig command line tool, and a single **Vercel Native** application shell that covers Windows, Linux, macOS, Android and iOS. Electron and Capacitor both go. The React user interface is carried across unchanged and is not ported: Vercel Native embeds a directory of built frontend assets and serves them to the system WebView, so the UI keeps being TypeScript and React and becomes the only TypeScript that ships.

**Bun stays.** Wherever TypeScript or a script survives into the new repository, Bun is what runs it: the workspace and its dependencies, every `package.json` script, the bundling of the React frontend, the TypeScript unit tests, and the host-side pieces of the smoke test harness. The one thing that may not be Bun's to run is the Vercel Native CLI itself, which ships on npm and states Node 22.15+ as its requirement; whether it runs under Bun is a question for prototype P1 and is not assumed here.

The work is cut into individually testable packages, each with a plan, unit tests and (where reachable from outside) smoke tests. Execution is autonomous: the orchestrator picks the next ready package, an implementation agent builds it in its own worktree and commits, a review agent checks it against the plan and runs the tests, and the two hand back and forth until the review passes.

**A port that produces nothing runnable until it is two thirds finished cannot be trusted or stopped at**, and a new repository has that risk by construction, because nothing calls the new code until something is built to call it. Three constraints answer it: the walking skeleton is built before any core library, the command line tool comes online early because its eighty smoke tests are headless and run anywhere, and **every package after the skeleton must name a test that goes from red to green**. A package that cannot name one is the wrong package.

**This port gets done.** Nothing here is a question about whether it happens, only about how: which route, which dependency, which platform arrives first. A negative result changes the route. Consequences: an agent that hits a wall reports it and takes the next rung of the escalation ladder rather than deciding the work is off, and never invents a workaround the rules forbid.

## Prototypes: the ten questions to answer first

**These are built in phase 2**, driven from the meta repository by the orchestrator, each in its own throwaway repository: a session does the work and a workflow runs whatever needs a platform the session does not have. Three exist already, built by hand. Phase 3 absorbs the findings.

**P2 is the exception.** It asks whether the generated Xcode project builds under Xcode 14.2, which no current runner image is likely to carry, so it runs on a Mac the port can reach or is done by the human.

**These briefs are copied into `docs/prototypes.md` in the meta repository during phase 0**, which is where each one's repository link and finding are added as it is built. Add the link here too as each lands, so this plan stays readable on its own.

A usable finding says what was run, on what, and what happened. A negative result moves work (different route, different dependency, a platform shipping later) and is never worked around quietly.

**Built already:**

- https://github.com/ashleydavis/electron-alternative-vercel-native, the Vercel Native probe: window, bridge, events, localhost media server with range requests, WebSocket, built and run on Linux. What it covers and what to take from it is the section below.
- https://github.com/ashleydavis/electron-alternative-zig-with-webview, the same problem against the raw `webview` C binding. Not the chosen route, but its message queue and its comparison of the two are worth reading.
- https://github.com/ashleydavis/what-changed, a Zig command line tool ported from TypeScript, including a port of `commander`. Not a prototype of the application, but it is the reference for how the Zig here is written and it is already a dependency of this repository.

**P1. The desktop shell, ejected, on Windows, Linux and macOS.** The Vercel Native probe covers this on Linux with the zero-config build. What is not covered: the other two desktop platforms, and the ejected build, which the port has to use because zero-config has no `build.zig` and this application links C libraries. Run `npx native eject` and confirm the whole of the probe still builds and runs from the owned `build.zig` and `build.zig.zon`, including the frontend embedding and the packaging commands.

It answers usefully when it reports the exact SDK version, the exact Zig version, the system packages each platform needs, and these four:

- **Whether the SDK CLI runs under Bun**, across `native build`, `native check`, `native package` and both mobile targets. If it needs Node, which commands.
- **How the frontend is bundled by Bun**, given Tailwind and PostCSS, which `bun build` does not carry. Either `bun build` plus Tailwind's own CLI as a separate Bun-driven step, or Vite invoked by Bun. Build a real Tailwind page, because a page with no Tailwind in it proves nothing.
- **How the frontend gets a fast development loop**: a watched build writing into the embedded dist, or an allowed development origin in `app.zon`'s navigation policy, and what the second does to the security model.
- **What the shipping answer is for the WebKit sandbox** on distributions that restrict unprivileged user namespaces, given that the probe's development workaround of disabling it is not shippable.

**P2. iOS under macOS 12.7.6 and Xcode 14.2.** The project's supported Apple toolchain is pinned to those versions, which is why the current repository is stuck on Capacitor 5. Vercel Native generates an Xcode project and expects `xcodebuild -scheme <app> archive` to work with no hand edits, its mobile support is vendor-labelled experimental, its mobile documentation page is a 404, and nothing in the probe has ever been built for a phone.

It answers usefully when a generated project builds, installs and launches on the simulator from the pinned toolchain, a bridge command returns a value, an emitted event reaches the page, and a loopback socket can be bound and reached from the WebView, since the asset server depends on that. If it does not build, the exact error matters more than the conclusion.

The choice that follows a negative result is the human's: raise the Apple toolchain and lose local iOS development on the current Mac, get a newer Mac, or ship iOS later than the other platforms. The port continues either way; what changes is which packages have an iOS lane.

**P3. Android through the SDK's own toolchain.** The same three things through `native dev --target android`, installed on an emulator. It answers usefully when it also reports how the SDK's emulator handling interacts with a pool that is already running, because the port's Android runner uses the pool and its monitor rather than starting emulators of its own.

**P4. The C libraries on every target.** The port needs the AWS C runtime for S3 (`aws-c-s3` and its stack, plus `s2n-tls` on Linux and Android and the Apple TLS stack on macOS and iOS), OpenSSL or BoringSSL for AES-CBC, RSA and PEM (Zig's standard library has no CBC mode and no RSA), and libbson for BSON.

It answers usefully when all three build and link into an ejected build for Linux, Windows, macOS, both iOS targets and all three Android ABIs, and when each is pinned by exact tag and content hash rather than a branch, with its licence recorded. A library that will not build for a mobile target is a finding the port has to design around, not something to substitute quietly: hand-writing SigV4, a TLS stack or a BSON codec is banned here whatever the reason.

**P5. The real user interface in each system WebView, including video.** This is the largest uncovered risk after iOS, and there is evidence for it in this repository already.

The probe renders plain HTML, CSS and JavaScript. Photosphere's user interface is a React application with a router, Tailwind, a gallery that renders fifty thumbnails at once, a full-screen viewer, and video playback. Electron ships its own browser engine with its own codecs; WKWebView, WebKitGTK and WebView2 are the operating system's, and on Linux the codecs come from whatever GStreamer plugins are installed. `docs/electron-video-playback-fix.md` records that this application has already lost video twice for reasons of exactly this kind: a `blob:` URL created from a `file://` origin was rejected by the media URL-safety check while the same URL worked for `<img>`, and once it loaded it painted solid black until hardware acceleration was turned off. The application is served from `zero://app`, a custom scheme, which is precisely the sort of origin that trips those checks.

Build it: the real built frontend, loaded by the shell, with the real gallery pointed at a real database fixture through a minimal media server, on Linux, Windows, macOS, Android and iOS.

It passes when, on every platform: routing works under the custom scheme including a deep link and a reload, Tailwind styling arrives intact, fifty thumbnails render and scroll without visible failure, an image opens full screen, an h264 MP4 and whatever other formats the fixtures contain play with sound and seek through a range request, and the page can talk to the loopback server cross-origin. Record which codecs each platform decoded and which it refused.

A negative result here changes what shipping means: a Linux user without the right GStreamer plugins gets a photo application that cannot play their videos, and the answer is a declared dependency, a bundled decoder, or transcoding on import. Find out which now rather than after a release.

**P6. Mobile platform capabilities, in a project the SDK generates.** The mobile applications today are not only a WebView. They carry native code for importing files, exporting and sharing them through a `FileProvider`, secure storage over the Android Keystore and the iOS Keychain, and a set of `Info.plist` and manifest entries that the application does not work without, including `NSAppTransportSecurity` with `NSAllowsLocalNetworking` for the loopback asset server and LAN sharing.

The SDK generates the Xcode project and the `AndroidManifest.xml` from `app.zon`. Generated projects are at their worst exactly here, because everything a hand-written project would add is something a generator has to have a place for.

Build it: an SDK-generated mobile application that picks a file through the platform's own picker and reads it, writes a file out and shares it, stores and retrieves a secret from the platform's secure storage, binds a loopback socket and serves one byte to its own WebView, and carries a custom `Info.plist` key, a custom Android permission and a `FileProvider` declaration that survive a regeneration.

It passes when all six work on a device or emulator and none of them required editing a generated file by hand. If any of them requires hand-editing generated output, the finding says which, because that becomes a build step somebody has to maintain forever.

If the SDK exposes none of this and offers no way to add platform code, that is a much bigger finding than a missing convenience, and it goes to the human before anything else is built.

**P7. The bundled media tools on mobile.** Photosphere runs ImageMagick and ffmpeg on the phone, today through native runner classes over a vendored ImageMagick build on iOS and an NDK-compiled library plus ffmpeg-kit on Android. In the new application there is no Java or Swift runner layer to hold them, so they become C libraries linked into the Zig binary or bundled beside it.

Build it: ImageMagick and ffmpeg reaching the Zig side of an SDK-generated mobile application, converting one real photo and probing one real video, on both platforms.

It passes when both run on a device or emulator and the resulting application size and startup time are measured and written down. Report the licensing position of whatever ffmpeg build is used, because it links into a shipped binary.

This is separate from P4 because P4 asks whether the build system can link C libraries and this asks whether the two largest and most awkward ones can be carried into a generated mobile project along with their data files and their size.

**P8. Concurrency, cancellation and progress under Zig 0.16.** The probe runs one background job, guarded by an atomic so a second cannot start, and reports progress through a single monotonic counter. Its own README says that stops working the moment more than one job runs. Photosphere runs many tasks at once, cancels them by source, and streams messages from them to the user interface.

Build it: a thread pool running several tasks concurrently, each with an id, each streaming progress and messages to the page, each cancellable individually and by source, with cooperative cancellation through a token, deadlines on every blocking wait, and a shutdown that cancels everything and waits with a bound. Under Zig 0.16, where blocking goes through a `std.Io` instance rather than free functions.

It passes when a hundred tasks run, are cancelled midway, and the page receives every event attributed to the right task with none lost and none duplicated, and when a task that ignores its cancellation token is reported as a timeout rather than hanging the shutdown. Run it under `ReleaseSafe` and under the leak-checking allocator.

**It must also cover a task that fans out inside itself.** Between tasks the mapping to threads is direct: one task, one thread, and the old repository already runs its handlers in pools. Inside a task is different, and it is the case the probe does not cover. An `await` in the middle of a handler is interleaved input and output within one piece of work, and on a single thread in TypeScript a `Promise.all` over fifty uploads runs all fifty at once for nothing; in Zig that task holds one thread and does them one after another unless it fans out itself. Measure one task issuing fifty concurrent operations against the same fifty done serially and against fifty separate tasks doing one each, and find out whether a handler that fans out onto the pool it is running on can deadlock itself when the pool is full. The likely cases in the old repository are S3 multipart upload and any handler batching network requests.

This is the model that packages 23, 33 and 36 are built on, and it is the one piece of the architecture that has no equivalent anywhere in the current repository, because there the concurrency came from an event loop that no longer exists.

**P9. Compatibility with data and installations already in the field.** Users have databases on disk written by the TypeScript, and after this ships they will have a Zig phone talking to a TypeScript desktop over LAN sharing, because nobody upgrades everything on the same day.

Build it: a Zig program that opens a real database written by the current application, reads its records through libbson, reads its serialised structures, and computes the same merkle root hash the TypeScript computes, asserted against the checked-in fixtures. Then, smaller: a Zig LAN share sender against the current TypeScript receiver, and the reverse.

It passes when the root hashes match on every fixture database in the repository, when every record compares equal field for field, and when a database written by the Zig side is opened by the TypeScript side without complaint. Where libbson and the `bson` npm package disagree, name the type.

This decides whether the work is a port or a port plus a migration, and that has to be known before the port starts rather than when the first user opens their library.

**P10. The autonomous loop itself, on a throwaway package.** The port is meant to run without a human in the loop for long stretches. That machinery has never been run.

Build it: one real cycle of the loop in the real runner environment, on a small package of work that does not matter. Orchestrator picks it, implementation agent builds it in a transient worktree and commits with the hook enabled, review agent runs the tests itself and rejects it at least once on purpose, they iterate, the orchestrator merges, runs the full suite, removes the worktree and updates the state file.

It passes when a package goes from ready to merged with no human intervention, when a deliberately broken implementation is caught by the review agent rather than merged, and when killing the orchestrator mid-cycle and restarting it loses one cycle rather than confusing the state. Record what the cycle cost, because that number times forty is the port's budget.

This is the one prototype in the list with nothing to do with Zig or the SDK, so it does not need a repository of its own: running it as the orchestrator's first cycle against a throwaway package in the new repository is the same experiment.

Run it in the environment the port will use, so it also answers the environment questions. For cloud sessions, measure rather than assume: availability on the account; whether the network allowlist reaches everything the toolchain and the C dependencies need; whether all three repositories attach at once; whether 30 GB of disk and 16 GB of RAM hold `photosphere-old`, `photosphere-zig`, worktrees, the Zig cache and a C library build together; how long a session runs before it ends; how many run concurrently; whether merging by pull request works end to end; and what a session costs. For a droplet instead: what `ls -l /dev/kvm` says, and whether the application smoke suite runs under `xvfb`.

## What the new repository contains

**The layout mirrors the old repository**, because that is what rule 1 is for. `packages/storage/src/file_storage.zig` sits against `packages/storage/src/lib/file-storage.ts`, and a human comparing the two does it by path rather than by translating a layout in their head. Every directory that exists in the old repository and still has a job keeps its name and its place. The only departures are where the new stack forces one, and each is marked below.

```
photosphere-zig/
  README.md
  CLAUDE.md
  package.json            Bun workspace and scripts, and the pinned Vercel Native CLI
  bun.lock
  mise.toml               pinned Zig, Bun, jq, what-changed
  what-changed.yaml       which suites run for which paths
  build.zig               owned (ejected), because C libraries have to be linked
  build.zig.zon           C dependencies, each pinned by exact tag and content hash
  app.zon                 the Vercel Native manifest: windows, capabilities, security, frontend
  THIRD-PARTY-NOTICES.md

  src/                    NEW. The Vercel Native host, at the root because that is where the SDK
    main.zig              expects it. Bridge handlers, the wake and drain hand-off, entry point.
    asset_server.zig      Replaces apps/desktop's main process and both mobile shells.
    events.zig

  packages/               one directory per old package, same names, Zig tests beside the code
    api/src/
    bdb/src/
    encryption/src/
    fuzzy-match/src/
    lan-share-network/src/
    merkle-tree/src/
    node-api/src/
    serialization/src/
    storage/src/
    task-queue/src/
    tools/src/
    utils/src/
    vault/src/
    user-interface/       carried across unchanged, still TypeScript, built by Bun
    config/               carried across if the UI still needs it

  apps/
    cli/
      src/main.zig        the Zig command line tool
      src/cmd/            one file per command
      src/lib/            shared code, including the port of commander
      smoke-tests/        the eighty numbered tests, same numbers and names
      smoke-tests-*.sh    the encrypted, LAN share, sync, write lock and hash cache suites
    smoke-tests/          the application smoke suite, run on every platform
      tests/              the deduplicated tests, same names as the old repository's
      lib/                the harness: runner, control bridge, process control

  scripts/                the operational scripts, carried over
    lib/                  temp directory allocator, process control, concurrency, timeout

  .githooks/pre-commit    frozen, copied unchanged
  .github/workflows/      the old repository's release workflow, adapted
  docs/                   the documentation set, written in phase 0
  test/dbs/               the checked-in fixture databases, carried over
```

**What is gone from the old layout, and why:** `apps/desktop`, `apps/desktop-frontend`, `apps/android-frontend` and `apps/ios-frontend` collapse into `src/`, because there is one application shell instead of three. `packages/mobile-worker`, `packages/mobile-frontend` and `packages/rest-api` disappear entirely. `apps/bdb-cli` and `apps/mk-cli` are decided when `packages/bdb` and `packages/merkle-tree` land.

**No process artefacts live here.** The plans, queues, evidence, journals and summary are in the orchestrator repository. This one is code, tests and documentation.

What is Zig: everything that was `packages/` except the user interface, everything that was `packages/node-api`, `packages/rest-api` and `packages/mobile-worker`, the command line tool, and the application host.

What stays TypeScript: `packages/user-interface` and whatever it needs, the host-side smoke test control bridge, and the build tooling. All of it is run by Bun, and none of it is present at runtime in a shipped binary.

Bun's specific jobs, so that no part of this is left to preference:

- **The workspace.** `bun install`, workspace packages, and the lockfile, exactly as the current repository does it.
- **Every script.** `bun run compile`, `bun run test`, `bun run test:cli` and the rest, with the same naming as today so the muscle memory carries over. Shell scripts are still shell and are still invoked through their `bun run` name rather than directly.
- **Bundling the frontend.** `bun build` is the intended bundler. The current frontend is built by Vite with the React plugin, Tailwind and PostCSS, so this needs an answer for the Tailwind and PostCSS pipeline, which `bun build` does not carry. Step 2 settles it: either Bun drives Tailwind's own CLI as a separate build step, or Vite stays and Bun invokes it. Do not decide it here and do not assume `bun build` alone is enough.
- **TypeScript tests.** `bun test` for whatever unit tests the frontend keeps, replacing Jest and `ts-jest`. Zig tests stay with `zig build test`.
- **Typechecking.** `tsc --noEmit` under Bun, as now.

What disappears with no replacement: Electron, Capacitor, the embedded JavaScript engines and their host bridge, `packages/mobile-worker` and its nineteen Node shims, `packages/rest-api` and Express, the Electron worker pool, the `@aws-sdk` packages, `bson`, and the mobile crypto polyfill set that existed only to run the AWS SDK inside a bare JavaScript engine.

## Vercel Native: what it gives, what it costs

Everything here comes from the probe at https://github.com/ashleydavis/electron-alternative-vercel-native, which is a record of what was built and run rather than what the vendor documents claim.

Three channels between the frontend and Zig:

- **The bridge**, for control flow. `await window.zero.invoke("native.command", payload)` runs a Zig handler and resolves with a JSON value. Zig pushes the other way with `runtime.emitWindowEvent(window, "name", detail)`, received by `window.zero.on`. Events carry validated JSON and escaped names, so there is no script injection surface. This replaces every Electron IPC channel and every Capacitor plugin call.
- **A localhost HTTP server**, for bytes. The bridge settles a promise with a JSON value, so images and video cannot go through it. The probe serves media from `127.0.0.1` on an OS-assigned port with range request support, and the page asks Zig for the port over the bridge because the page is on `zero://app` and is therefore cross-origin to the server. This is what the asset server becomes.
- **A WebSocket**, for a long-lived duplex channel. This is what task progress, toasts and news notifications become.

The threading rule that everything obeys: the WebView belongs to the UI thread. A worker publishes into atomics and calls `wake()`, which is a bounded non-blocking enqueue any thread may call; the loop thread then drains and emits. Nothing but the drain touches the WebView.

### Several of this port's load-bearing features are already prototyped there

**Read the probe before writing any of these and start from its code, not from the SDK documentation**, which it found wrong or silent on two of its three central APIs. The mapping onto the work packages:

| Prototyped in the probe | Where it lands here |
| --- | --- |
| Window, manifest, and a frontend directory embedded into the binary at build time | The skeleton, package 6 and 8 |
| Bridge handlers with a per-origin command policy, invoked from the page and answered with JSON | The platform provider, package 36, and every handler call the UI makes |
| Zig to page events with validated JSON and escaped names | The event channel, package 36 |
| A background worker on its own thread publishing progress through atomics, with the `wake` and `drain` hand-off, release/acquire ordering, and a high-water mark that coalesces late wake-ups instead of dropping them | The task queue and its progress streaming, package 23 |
| An atomic guard rejecting a second job while one runs, and the note that the page cannot be trusted for this because the bridge is reachable from the DevTools console | Package 23, and the validation rule for every bridge handler |
| A localhost HTTP server: OS-assigned port from binding zero, loopback only, range requests including `bytes=start-`, `bytes=start-end`, 416 past the end and a response cap, cross-origin headers and preflights because the page is on `zero://app`, and a path traversal answer that never joins a request path onto a directory | The asset server, package 34. This is the closest match in the probe to a Photosphere feature: it is the same job the current asset server does for gallery thumbnails and video |
| A WebSocket carrying both directions: the upgrade ending the HTTP conversation on that socket, a mutex because two threads write to one socket, the reader joined rather than detached because it borrows the connection thread's stack, pongs written by hand, and the page reconnecting after a close | Notifications and task messages, packages 35 and 36 |
| The SDK's automation harness (`-Dautomation=true`): a file-based command dropbox that drives the bridge, resizes the window, takes snapshots and dumps the accessibility tree, and is how the probe was verified with nobody clicking | The test harness, package 7. Evaluate it against the existing control bridge before porting the control bridge: if it can drive the application on all five platforms it may replace the in-app test surface entirely, which would remove test-only code from the application |
| Measured binary sizes, what is embedded, what is not, and what a copied binary still needs from the system | Packaging, package 46 |

Three things in the probe must not be copied as they are:

- It builds JSON with `bufPrint`. Use `std.json` throughout: `bufPrint` breaks the moment a filename or user string enters a payload.
- Its bridge policy allows `zero://inline` for the automation harness. That is a security decision to take deliberately, not inherit.
- Its progress path is one monotonic counter, which its README says stops working with more than one job. Package 23 needs task ids in every event and a real queue. The sibling probe at https://github.com/ashleydavis/electron-alternative-zig-with-webview has that queue as a fixed-capacity ring buffer.

The costs:

- **Zig 0.16.0 exactly**, pinned by the SDK. Zig 0.16 routes sleeping and other blocking through a `std.Io` instance rather than free functions, which changes how every blocking call in the port is written.
- **A JavaScript runtime is a build-time dependency**, because the SDK ships as an npm CLI stating Node 22.15+. Open question, answered by P1: whether the CLI runs under Bun. If it needs Node, Node is pinned in `mise.toml` for that one purpose and nothing else.
- **The shell builds on the target operating system**, because it links platform SDKs and system libraries. The command line tool does not: it links nothing platform-specific, and `what-changed` cross-compiles all four desktop targets from one Linux machine today.
- **Linux needs GTK4 and WebKitGTK 6.0 development packages**, and the runtime needs `libgtk-4-1` and `libwebkitgtk-6.0-4`. Ubuntu ships the GTK3-era `libwebkit2gtk-4.1` by default, so this asks more of a user's machine than Electron does and has to be declared in whatever gets shipped.
- **Ubuntu 24.04 and friends restrict unprivileged user namespaces**, which kills WebKit's sandbox and makes the app exit at launch. The probe works around it by disabling the WebView sandbox in dev, which is not acceptable for anything shipped. The shipping answer is a decision this port has to make and record.
- **Mobile is vendor-labelled experimental and nothing has been built for a phone.** The CLI carries a real mobile toolchain (it generates an Xcode project with pbxproj, scheme, `Info.plist` and asset catalog, and drives the NDK, writes an `AndroidManifest.xml`, assembles a debug APK, boots an emulator and installs over adb), and all of that is read from the CLI rather than run. The mobile docs page is a 404.
- **The probe's own note about porting**, worth repeating because it is about this exact application: the Zig core and the bridge would come across unchanged, but the localhost HTTP server and the WebSocket both bind loopback sockets, which iOS is unfriendly about, and a fixed window size means nothing on a phone.
- **`@native-sdk/cli` went from 0.0.0 to 0.8.4 in about five weeks.** Pin the exact version, never a range, and treat an upgrade as its own work package with the full suite behind it.
- **The SDK's documentation is not a reliable specification.** Two of the three central APIs in the probe's `src/main.zig` were undocumented or documented wrongly and had to be recovered by reading `node_modules/@native-sdk/cli/src`. Budget for reading the SDK source.
- **Zero-config means no `build.zig`.** This port needs one, because it links C libraries (the AWS C runtime, OpenSSL or BoringSSL, libbson). `npx native eject` writes an owned `build.zig` and `build.zig.zon`. Whether an ejected build still gets the mobile toolchain, the asset embedding and the packaging commands is a question for prototype P1.

## Two rules for every line of Zig in this port

These are not style preferences. They are what makes the port reviewable by a human and by a review subagent, and they belong in the new repository's `CLAUDE.md`.

Both rules have already been worked out in practice, on a smaller Zig port by the same author, and the next section is the evidence for them.

### 1. The Zig emulates the TypeScript, so the two can be compared line by line

The reason this port can be trusted at all is that a reader can put the TypeScript and the Zig side by side and check them against each other. That only works if the Zig is a transliteration rather than a redesign.

- One Zig file per TypeScript file, at the same relative path, base name with `-` replaced by `_`.
- Declaration order matches the TypeScript. Function names match the TypeScript. Parameter order matches the TypeScript.
- Control flow matches the TypeScript: the same branches, in the same order, with the same early returns. Do not merge two loops into one, do not hoist a condition, do not replace a loop with a cleverer formulation.
- Interfaces lose the `I` prefix and become a struct with a vtable (`IStorage` becomes `Storage`), and their method names are unchanged.
- Port what is used, not what exists. A function nobody calls, an option nobody passes and a branch nothing reaches are all behaviour with no test behind it. Where a subset is ported, the file says at the top what was left out and why, by name.
- What gets reproduced exactly, to the character, is anything a test or a script can see from outside: error wording, help layout, exit codes, output formats and on-disk formats. A shell script driving the new tool must not be able to tell the difference.
- Improvements are not free. A better algorithm, a tighter data structure or a fixed bug in the middle of a port destroys the comparison for everything around it. If something in the TypeScript is wrong, port it faithfully, say so at the time, and let the human decide whether to fix it in both or in neither.

**No comment justifies anything by pointing at the TypeScript.** This is the one place the rule bites its own tail, and it is worth stating carefully because getting it wrong produced 43 useless comments across 19 files in the last port, all of which had to be deleted afterwards. A comment saying "the TypeScript did it this way" names something the reader cannot open, to justify a choice nobody has restated, and it becomes worse than nothing the day the old repository is archived. Every comment gives its reason on its own terms. Where the only reason for a decision was to keep the two implementations comparable, find the durable reason as well and write that one down instead. The same goes for test names: a test is named for the behaviour it checks, never for the implementation it was copied from.

The correspondence itself is recorded once, in a place built for it, rather than scattered through the code: each ported file carries a single `// Port of packages/<pkg>/src/lib/<file>.ts` header line, the porting index in the documentation maps old file to new file, and both are porting metadata with an end date. Package 47 removes the header lines when parity is reached, exactly as the previous port did. Divergences get a comment at the site saying what the Zig does and why, on its own terms, plus an entry in the divergence document; the known ones are listed at the end of this plan.

### 2. Pure and functional, with globals only at the edges

- A core library function takes what it needs as parameters and returns what it produces. No process-wide state, no lazily initialised singleton, no module-level mutable variable, no hidden cache, no ambient logger, no ambient allocator.
- `packages/**` gets no mutable globals at all. Constants are fine. A `const` table is fine. A `var` at module scope is not, whatever it is protecting itself with.
- State that has to exist lives in a struct the caller owns and passes in, so two of them can exist at once and a test can make one.
- Effects are parameters: the allocator, the `std.Io`, the clock, the UUID source, the network and the process spawner all arrive explicitly, which is also what makes the deterministic test implementations the smoke tests rely on possible. A struct may hold the effect it was constructed with, because a temporary directory only makes sense against the filesystem that made it, but nothing reaches for an effect it was not given.
- The test for whether this rule is being followed: reading a function tells you which implementation a call uses, and no test can change what another test sees. If either fails, there is a hidden global whatever it is called.
- Globals are tolerated only at the edges: `src/main.zig` and the platform host it talks to, the CLI entry point, and the process-level runtime the SDK owns. Even there, the global is a container that is constructed once at startup and passed down, never reached back up into.
- Keep a written list of every container-level variable left in the repository, and drive it down. The last port ran that list to four and named them.
- The old `setQueueBackend`/`getQueueBackend` process singleton is the exact pattern this rule exists to stop. It does not come across.

## Determinism, and zero flaky tests from the first commit

**This is the most important quality requirement in the port, and it outranks the rule that the Zig mirrors the TypeScript.** Where the two conflict, determinism wins and the divergence is recorded. A port that reproduces the old behaviour but is unreliable is worth less than the thing it replaced, and an autonomous system cannot function on top of tests that sometimes fail: every flaky test poisons the review, the merge train and the release workflow at once, and an agent cannot tell an unlucky run from a real defect.

The old repository has zero tolerance for this and has paid for it in scripts, rules and hard-won knowledge. All of it comes across, and the new repository starts with it rather than acquiring it after being bitten.

### The determinism rules, which go in `CLAUDE.md`

**New Zig code must be deterministic. Same inputs, same outputs, every time, on every platform, in any order, at any concurrency.**

- **Functions are pure where they possibly can be.** Inputs in, result out, nothing else observed and nothing else touched.
- **Every effect arrives as a parameter**: the allocator, the `std.Io`, the clock, the random source, the UUID source, the environment, the network, the process spawner. A function that needs the time takes a clock; it does not read one.
- **No globals**, which is already rule 2 and is restated here because a mutable global is the most common way determinism is lost.
- **Side effects are minimised and named.** A function that writes, spawns or sends says so in its name and its comment, and everything else is free of them.

**The specific sources of nondeterminism, all banned outright in core code:**

- **Wall-clock time and dates.** Through the clock parameter only. No `std.time.timestamp()` buried in a library.
- **Randomness**, including UUID generation. Through a source parameter, seeded explicitly. The deterministic test implementations that the old smoke tests rely on through `NODE_ENV=testing` come across for exactly this reason.
- **Hash map iteration order.** Zig's hash map iteration order is not specified and shifts with capacity and insertion history. Anything whose output depends on it (a serialised document, a hash, a report, a listing) sorts explicitly first. This is the single likeliest way a port of TypeScript, whose objects preserve insertion order, becomes nondeterministic without anybody noticing.
- **Filesystem ordering.** Directory reads come back in whatever order the filesystem gives, which differs between platforms and between runs. Sort before use, always.
- **Uninitialised memory.** Zig's `undefined` is a recognisable pattern in debug builds and real garbage in release, so a read of uninitialised memory can pass a thousand debug runs and fail in `ReleaseFast`. That is why every test runs in `ReleaseSafe` as well.
- **Pointer values and addresses**, which vary per run, and anything derived from them.
- **Thread scheduling.** Results from a pool are collected into a defined order before anything looks at them. A test never depends on which thread finished first.
- **Locale, environment and platform formatting**, including float formatting, which the port pins explicitly wherever a value is serialised.

### Fuzzing, and differential fuzzing against the TypeScript

Zig has a built-in fuzzer, and this port has something better than a fuzzer's usual oracle: **a working reference implementation**. Both are used.

- **Fuzz every parser and every format.** The binary serialiser and deserialiser, BSON, the encryption header, storage path parsing, the storage descriptor parser, the asset server's route parameters, and the LAN share wire format. These are where malformed input meets code that assumes it is well formed.
- **Round-trip properties**: decoding what was encoded returns the original, for every input the fuzzer can produce.
- **Differential fuzzing is the strongest tool available here.** Feed the same generated input to the Zig and to the TypeScript, and compare the outputs byte for byte. A divergence is a defect in the port, found automatically, with a reproducing input attached. This is worth building for the formats that cross machines or persist to disk, because those are the ones where a divergence is expensive and silent.
- **Every fuzz finding becomes a named unit test** with the failing input as a fixture, so it can never regress silently.

### The two scripts, run by every review, on every package

`scripts/find-flakey-tests.sh` and `scripts/check-parallel-tests.sh` come across from the old repository, and they are not optional extras. **Every review agent runs both before accepting work in a worktree**, and a package is not accepted until both pass:

- **`find-flakey-tests` on the ladder, ten runs a rung.** Every suite, cheapest rung first, requiring ten consecutive green runs of each before the next rung starts. Ten rather than the default hundred because this runs on every package rather than once; the hundred-run sessions are for the periodic sweeps and for hunting a known flake.
- **`check-parallel-tests`, with all suites included.** Every suite alone, then every combination of two, self-pairs included. Self-pairs are the cheapest way to catch a fixed port or a fixed path, and this port runs several agents at once so a suite that cannot survive beside a copy of itself is broken by definition.

Both must cover **all** tests. A run that quietly leaves a suite out is worse than no run, because it reports clean.

### Parallel safety is proven for every new test, not assumed

**Absolute rule from the first commit: every test must run beside another copy of itself and beside every other suite.** Several agents run tests at once, on the same machine, from different worktrees, so a test that needs to be alone breaks the whole system rather than just itself.

The old repository's rules come across unchanged and are enforced by review: no hardcoded port, no fixed path anywhere including under a temp directory, no fixed database, bucket, vault, config or lock name, no fixed device. Ports are allocated free, directories come from the temp directory allocator, every started process has its pid recorded at the moment it starts, and nothing is ever killed by matching a command line.

New tests do not inherit the old ones' proof. Each one is shown to be parallel-safe by `check-parallel-tests` including it, and the review checks it was included rather than taking the summary line on trust.

### The release workflow is never left failing

- **An obvious failure is fixed immediately**, ahead of any other work. A red workflow on main is the highest priority thing in the port, because everything after it builds on a tree nobody has proven.
- **A flaky failure stops everything.** Not the package, everything. No new work starts while a flake is loose, because every run after it produces evidence nobody can trust.
- **A flake is only considered fixed after five complete release workflow runs pass in a row**, every job, every platform. Not a targeted rerun of the job that failed: the whole workflow, five times, sequentially.
- **A rerun is never a fix.** A job that goes green on retry has told you it is flaky, and that is a finding to chase rather than a result to accept.

### The flakiness log, and learning from every instance

`docs/flakiness/` in the meta repository holds one entry per flake ever seen, and it is a deliverable rather than a diary. Each entry records:

- **What flaked**: the test or the code, by name, with the run that caught it.
- **Why**: the actual mechanism, not a guess. An entry that says "timing" has not been finished.
- **How it was fixed**, and how that fix was proven: the ladder runs, the parallel check, the five sequential workflow runs.
- **What rule now prevents it**, written as a rule an agent can follow before writing the code rather than after.

**That last field is the point of the log.** Every rule it produces goes into the new repository's `CLAUDE.md` immediately, so every subsequent agent reads it before writing anything. The log accumulates the reasons; `CLAUDE.md` accumulates the rules. Over the port this should mean each class of flake is paid for once.

`summary.md` carries the count of open and resolved flakes, because a rising count is the earliest sign the port's quality is slipping.

## The reference implementation: `what-changed`

https://github.com/ashleydavis/what-changed is a Zig command line tool by the same author, already in daily use by this repository (its executable is what `bun run tev` needs on the PATH), and it is a port of a TypeScript program written under both rules above. It is the closest thing to a specification for how Zig is meant to be written here, and it is small enough to read end to end. **Read it before writing any Zig, and read its commit history, which is where the reasoning lives.**

What it settles, so that this port does not relitigate it:

- **The command line library is already ported.** `src/lib/commander.zig` is the parts of `commander` that a tool actually uses, in Zig, in about 1,200 lines. Photosphere's CLI is written against `commander` too, so this is not a similar problem, it is the same problem already solved. Lift it, extend it to whatever Photosphere's command line uses that `what-changed`'s does not, and extend the deliberate-omission list at the top of the file in the same edit.
- **How to port a library you cannot copy.** Its header says it is "an implementation of what is used, not of commander", lists by name what is missing on purpose (short flags, boolean flags, value parsers, `.requiredOption`, `.hook`, `opts()` inheritance, variadic and negatable options) and gives the reason: each one would be behaviour with no test behind it. What it does reproduce exactly is the wording of the errors and the layout of the help, because the smoke tests assert on both.
- **What to do about closures.** A `commander` action captures its surrounding scope and a Zig function pointer captures nothing, so an action takes a context pointer handed to `.action` alongside it, which is the same information arriving by a different route. Every TypeScript callback in this port that closes over state gets the same treatment.
- **Named constants carry their reason and what asserts them.** `HELP_TERM_WIDTH = 19` is not a magic number, it is what commander's own output measures and what the smoke tests check.
- **Error sets model the source's failure modes** and stay split where the caller treats them differently: asking for help and getting the command line wrong are separate errors because they exit 0 and 1.
- **`std.Io` is never global.** Zig 0.16 made every filesystem call take one, and the first version of `what-changed` kept a lazily created module-level instance so signatures stayed short. Commit `ef5eecb` removed it: every function that touches a disk or a clock now takes an `io` and passes it on, the context carries one, the file lister gained the parameter so it spawns git through the caller's implementation, and each test harness owns its own. The reason given is the one that matters here: with the global there was no answer at the call site to which implementation was in use, and two tests could not hold different ones, so whichever ran first decided for the rest. This port starts where that commit finished.
- **Structure.** `src/main.zig`, one file per command under `src/cmd/`, everything else under `src/lib/`, tests in the files they test, and a separate `perf-tests/` with budgets that fail the build when a stage gets slower. Photosphere's Zig CLI follows the same layout.
- **Testing conventions.** Every function has unit tests. Tests run against real temporary directories, real files and real hashing rather than mocks. The smoke tests drive the compiled binary rather than the source, because what ships gets tested rather than trusted. All three carry over, and the last one has a direct consequence for this port: the CLI smoke suites run against the built executable.
- **Documentation conventions.** `README.md` for what it does, `docs/DEVELOPMENT.md` for building and testing, `docs/HOW_IT_WORKS.md` for the internals, `docs/performance.md` for what a run costs. The step 1 document set follows the same division.
- **Cross-compilation works for a pure Zig tool.** Its release builds four desktop targets from one Linux runner into a `bin/<arch>/<platform>/` layout, which is the layout Photosphere's CLI already uses.

The one thing not to copy from it is scale. It is a small tool with a single-file config and no C dependencies, so its build is simple in ways this one cannot be.

## The operational tooling comes across, all of it

The port replaces application code, not the machinery around it. These are shell and TypeScript, so nothing about Zig makes them obsolete, and losing one is not noticed until the day it would have caught something.

Every item below is carried over, kept working, and covered by the phase 0 documentation. Where a script names Electron, Capacitor or a package that no longer exists, it is edited to name the new equivalent, never dropped.

- **`scripts/test-everything-parallel.sh` and the whole `test:everything` arrangement.** This is how a change is tested in this repository and it is what the git hook runs. It comes across with its parallel lanes, its per-script decisions, its `--plan` and `--force`, and its serial groups.
- **`what-changed` and `what-changed.yaml`.** The new repository uses the same tool the same way, targets and all, so a docs-only change still runs nothing and a Zig change runs what it affects. It is already a Zig program by the same author, so this is one dependency that gets simpler rather than harder.
- **The git hooks: `.githooks/pre-commit` and `scripts/install-hooks.sh`.** Carried over and then frozen again under the same rule: never edited, never bypassed, and never given an escape hatch.
- **`scripts/find-flakey-tests.sh`**, with its streak target, resume, ladder mode, finish-time estimates, and everything it knows about telling a real failure from a runtime crash or a sick emulator pool. Every review runs it.
- **`scripts/check-parallel-tests.sh`** (`test:parallel`), which runs each suite alone and then every pair together, self-pairs included. This is what catches a fixed port or a fixed path, and the plan's orchestrator runs several agents and worktrees at once, so it is load-bearing for the autonomy as well as for the human.
- **The whole Android emulator pool.** `scripts/android-pool-status.sh`, `apps/android-frontend/scripts/emulator-pool-monitor.sh`, `emulator.sh`, `emulator-config.sh`, `emulator-status-lib.sh`, `android-env.sh`, `psphere-pool.slice`, the pool repair and diagnose commands, and the rolling monitor logs. This took a long time to get right, it is what makes Android testing possible at all, and it is entirely independent of what the application is written in. It comes across whole. On the port's Android runner the pool is provisioned by the setup document and kept up by the monitor, and the rules about what may start, stop and repair it come across with it.
- **`scripts/lib/`**: the temp directory allocator, the process control library with `kill_process_tree` and `kill_process_group`, the concurrency helpers and the timeout helper. Every parallel-safety rule in this repository is enforced by these four files.
- **The smoke test harnesses**: `apps/smoke-tests/lib/runner.sh`, the control bridge, `android.sh`, `ios.sh`, the Android lock, and the `common.sh` files from all three suites. Deduplicated where the desktop and mobile versions do the same job, never dropped.
- **`scripts/run-mobile-tests.sh`, `scripts/android-smoke-tests-ci.sh`** and the mobile lock and status commands.
- **`scripts/s3-emulator.sh`, `scripts/seed-s3-bucket.ts`, `scripts/s3-object.ts`, `scripts/clear-s3-bucket.js`.** The S3 tests need real infrastructure and this is it.
- **`scripts/story-player.sh`** and the stories runs on Electron, Android and iOS, which become runs against the new shell on desktop, Android and iOS. Rendering every page at phone resolution is how mobile layout problems get found.
- **The media tool scripts**: `fetch-mobile-media-tools.sh`, `update-mobile-media-tools.sh` and their documents, adjusted to whatever prototype P7 settles for bundling ImageMagick and ffmpeg.
- **`scripts/measure-android-emulator-leak.sh`** and the performance and benchmark runs, plus the perf budgets that fail a build when a stage gets slower.
- **`.github/workflows/release.yml` and everything under `.github/actions/`.** This one is large enough to have its own rules, below.
- **The test fixtures**: `test/dbs/` and every checked-in database, image and video the suites point at. The Zig side needs them more than the TypeScript did, because they are the evidence that the ported formats match.

Two rules that go in `CLAUDE.md` about this: a work package may improve one of these scripts but may not delete or replace one without the human saying so in that message, and the review agent checks that any script a package touched still runs. If something here turns out to have no place in the new repository, that is a finding to report, not a decision to take.

### The release workflow is carried over intact and adapted minimally

`.github/workflows/release.yml` is 1,744 lines and 22 jobs covering tag preparation, compilation, unit tests, performance tests, seven separate CLI and harness suites, CLI builds for Linux, Windows (two variants), macOS x64 and macOS ARM64, desktop packaging across a matrix, Android and iOS unit tests, Android and iOS smoke tests, and the release itself, which depends on all of them. It is the most complete statement anywhere of what "this project works" means.

It is **copied over as a whole and then adapted**, never rewritten from a blank file. The requirement at the end of the port is that the old workflow and the new one can be put side by side and read as an almost one-to-one mapping, with only the changes the new stack forces:

- **Job names, order, dependency arrows, matrix layout, timeouts, caching, retry actions and artefact names all stay.** A job that exists in the old workflow exists in the new one under the same name unless the thing it tested is gone.
- **What changes is what a job runs inside.** Bun installs and Jest become Zig builds and the three Zig test passes; `bun build --compile` becomes a Zig cross-compile; `electron-builder` packaging becomes `native package`. The job around it is untouched.
- **The CLI suites barely change at all.** They drive a binary through a shell script, and the binary's behaviour is being reproduced exactly, so `smoke-test-encrypted`, `lan-share-smoke-test`, `hash-cache-tests`, `sync-tests` and `write-lock-tests` should read almost identically.
- **The application suites do change**, because the Electron and Capacitor jobs collapse into one application built by the SDK. Expect `android-smoke-tests` and `ios-smoke-tests` to keep their names and their runners and to change how the app is built and installed, and expect the desktop equivalent to appear where the Electron one was.
- **From the start, everything not yet implemented is commented out rather than deleted**, with a one-line note saying which package will restore it. A commented job is a visible debt with an owner; a deleted job is a coverage loss nobody notices. Each package uncomments what it makes real, and the review checks that it did.
- **The final documentation package diffs old against new** and records what changed and why, so the mapping can be checked rather than asserted.

The workflow runs on every branch push, which is why the port pushes package branches as it goes: a package's own commits get tested on every platform by the same workflow that will release them, long before the merge train touches main.

## The phases, and the two checkpoints in them

The port runs in five phases, and the first three exist so that the system itself is proven before it is trusted with forty packages at once.

- **Phase 0: setup and structure.** The meta repository, the stub new repository, the rules and the whole documentation set. No port code at all. **Ends at a human checkpoint.**
- **Phase 1: stand up the port orchestrator.** Turn a bare machine into something that can take turns, and prove it can before it takes one.
- **Phase 2: build the prototypes.** Answer the ten questions, driven from the meta repository, which is also the first real trial of the environment the port will run in.
- **Phase 3: intake of the prototype findings.** Absorb what the prototypes settled and change the plan where they changed it.
- **Phase 4: the walking skeleton.** A launchable application, the test harness, the operational scripts and the release workflow, all working before any library is ported.
- **Phase 5: the shakedown.** One package, end to end, through every part of the machinery, one at a time, iterating on the system until it needs no more changes. **Ends at a human checkpoint.**
- **Phase 6: the port.** Every remaining package, several in parallel.
- **Phase 7: the parity audit.** Prove the new repository matches the old one. Anything it finds becomes work packages and goes back to phase 6, and phase 7 runs again. The loop ends when an audit finds nothing.

Nothing about phase 6 is attempted until phase 5 has run clean, and nothing in phase 5 is attempted until phase 0 has been read and accepted.

## The cold start: how this gets going at all

Before phase 0 there is nothing: no meta repository, no runner, no orchestrator, and this plan sitting in the old repository where no part of the port can see it. This section is how that becomes a running system, and it is the one part that a human performs rather than reads.

**The human creates nothing.** The bootstrap is done by an agent in a session, from a machine that already has git and GitHub credentials, and the only thing a human supplies is the one thing an agent cannot: the credentials the automation will run under.

What the bootstrap session does, in one sitting:

1. Creates `psi-zig-port-orchestrator`, private, and pushes it with this plan in it as `docs/plan.md`.
2. Writes the scheduled workflow whose only instruction is to take a turn, and commits it.
3. Creates `photosphere-zig`, private, with an empty main branch, and clones `photosphere-old` into the meta repository.
4. Does the rest of phase 0: writes the queues, the journal, `docs/decisions/`, `docs/lessons/`, the interventions and flakiness directories, the commit template, `summary.yaml` and the `summary.md` rendered from it, the stub repository, the rules and the documentation set. 
5. Stops at the phase 0 checkpoint for the human to read.

**The one thing only a human can do is supply the credentials**, because they cannot be minted by an agent: the Claude credentials the scheduled turns will run under, added as a repository secret. Without them the workflow exists but cannot run. Everything else, including the repositories themselves, is created by the bootstrap session.

Under the long-lived architecture there is additionally a machine, and that is a genuine cost of that option: a droplet has to be brought up before anything can run, and the setup document describing how gets written afterwards from what was done rather than being followed. That is the wrong way round, and it is another reason to prefer scheduled turns.

Under the long-lived architecture there is a machine, and that is a genuine cost of that option: a droplet has to be brought up and prepared before anything can run, and the setup document describing how gets written afterwards from what was done rather than being followed. That is the wrong way round, and it is another reason to prefer scheduled turns.

**What has to exist beforehand either way**: the source repositories reachable on GitHub (`photosphere` and the prototype repositories), a machine with git and GitHub credentials for the bootstrap session to run from, and the Claude credentials above.

**The order the bootstrap session works in**, because each step depends on the one before:

1. Start the journal with an entry describing the cold start itself, before doing anything else, so that everything after it is recorded as it happens. The first journal entry being the creation of the journal is the right kind of circular.
1b. Write the first entry of `docs/decisions/`: the decisions already taken while this plan was written, listed in the section on that file. They predate the log and are recorded as such, so the log starts from a known position rather than from nothing.
2. **The plan is already in place** as `docs/plan.md`, put there by hand when the repository was created. From that moment it is the plan, and the copy in the old repository is a historical artefact whose first line says so. Every later amendment happens in the meta repository, with a journal entry saying what changed and why, so the plan carries the same history as the work.
4. Clone `photosphere-old` at the `mobile` branch, read-only.
5. Create `photosphere-zig`, private, with an empty main branch.
6. Write the port orchestrator setup document, `docs/orchestrator-setup.md`, described below.
7. Then the rest of phase 0: the queue directories, decisions, interventions, `summary.yaml` and `summary.md`, the stub repository, the rules and the documentation set.

**How the orchestrator starts the first time.** Once phase 0 is accepted, the first orchestrator turn is started the same way every later one is: on the chosen architecture, either a scheduled invocation or a loop on the runner, pointed at the meta repository with the instruction to take one turn. It reads the queues, finds phase 3 outstanding, and works. There is no separate startup path and no first-run special case, because a special case is a path that is exercised once and therefore never tested.

### `prototypes.md`: the briefs, then the findings

Written in phase 0 with the ten briefs copied out of this plan, then filled in as each prototype is built. It is the human's page while the prototypes are being done and the port's input afterwards, and it is the one place that answers "what did we learn before we started".

One section per prototype, P1 to P10, each holding:

- **The brief**, from this plan: the question, and what an answer has to include.
- **Status**: not started, in progress, or done, with a date.
- **The repository**, linked, once it exists.
- **The finding**, written when the prototype finishes: what was run, on what, and what happened. What worked, what did not, and what refused to work at all.
- **What it changed**: the versions it pinned, the decisions it forced, the work packages it moved, and where each of those was recorded. A finding that changed nothing says so.

**The findings are copied into the port's own documents as well**, per phase 3, because a version pinned only here is a version nobody building the thing will read. This file is the record of how it was learned; `mise.toml`, `build.zig.zon`, `docs/architecture.md` and the rest are where it is used.

Also link each finished prototype in this plan's own prototypes section, so a reader of the plan can get to it without going through another document.

### `bootstrapping.md`: starting the port, and restarting it after anything

Written for a human, in phase 0, and kept current. It is the document to open when something has gone wrong and nothing is running. It assumes the reader has forgotten everything and is possibly annoyed.

**Part one: starting it the first time.** From an empty machine to a turning loop: the credentials needed, running `scripts/setup-orchestrator.sh`, what it verifies, the command that starts the first turn, and how to confirm it is running.

**Part two: working out what state things are in**, before touching anything. Read the first line of `summary.md` for the heartbeat and what it thought it was doing. Compare it with the queues. Look at what is in `in-progress/` and `review/` and at those packages' agent records. Five minutes of this saves an hour of restarting the wrong thing.

**Part three: recovery, in increasing order of severity.** Each with the symptom, the check that confirms it, and the fix:

- **The orchestrator is stuck.** Heartbeat old, nothing declared. Kill it by the pid in the heartbeat line, start a turn.
- **The orchestrator is gone.** Nothing running. Start a turn.
- **The machine is gone.** New machine, run the setup script, start a turn. Nothing was on it that matters.
- **Worktrees lost with the machine.** Branches are on the remote; the next turn recreates what it needs from them.
- **A package is stranded mid-stage.** Do nothing: the next turn's reconciliation records and routes it.
- **`summary.md` disagrees with the queues.** The queues win. Correct the summary, record it.
- **Main is red.** Find the last green revision, work out which merge broke it, hand that package back. The workflow history is the record.
- **Total loss: nothing survives but GitHub.** This document plus the setup script rebuilds the whole thing, because every piece of state was committed and pushed as it happened. That is what the push-immediately rule buys and this is the case it was bought for.

**Part four: stopping deliberately**, and what happens to work in flight when you do (nothing bad: an interruption is recorded nowhere and costs one step).

**Part five: what to check after any restart.** That the summary matches the queues, that no worktree exists without a package pointing at it, and that anything in `in-progress/` has an agent record newer than the restart.

### The port orchestrator, and its setup document

**The machine that runs the loop is the port orchestrator.** There is one of it at a time. It plans, spawns implementation and review agents, drives merge trains, updates the summary and keeps everything moving. Multi-platform building and testing does not happen on it: that is pushed to branches and done by the release workflow on GitHub's own runners, which is what removes the need to own a Mac, a Windows machine or an Android host.

Two things: `scripts/setup-orchestrator.sh`, which does it in one shot, and `docs/orchestrator-setup.md`, which explains what the script does, what has to be true before it runs, and how to fix it when it fails.

**The script is not a breach of the no-tooling rule.** That rule is about process machinery: queue movers, summary generators, ledger builders, watchdogs, things that would run forever and whose bugs would be indistinguishable from the port's. This is environment provisioning, run once per machine, in shell, exactly like `install-hooks.sh` in the old repository. It is the one script this port has.

**What the script must be:**

- **Shell**, per the repository rules, with no other language embedded in it.
- **Idempotent.** Re-running it on a half-set-up machine finishes the job rather than breaking it. This matters because the first thing anyone does after a failure is run it again.
- **Loud on failure**, stopping at the first one and saying which step failed and what to do.
- **Verbose about what it did**, so the machine's state can be understood afterwards from the output.
- **Silent about secrets.** No token is ever echoed, logged or written to a file.

### Authenticating git and `gh` on a fresh machine

This is the part that blocks everything else, so it is handled first and explicitly.

- **One GitHub token does both.** The script takes it from the environment (`GH_TOKEN`), never as an argument, because arguments are visible to other processes. It runs `gh auth login --with-token` from that variable, then `gh auth setup-git`, which points git's credential helper at `gh`. After that both `gh` and plain `git push` work over HTTPS with no keys to manage and no prompts.
- **The token needs `repo` and `workflow` scope**, since the port pushes workflow files.
- **Git identity is set explicitly** by the script (`user.name`, `user.email`), because commits from an unconfigured machine either fail or land with a useless author.
- **Where the token comes from** depends on where the orchestrator runs: an environment variable on a droplet, or a repository secret under the scheduled-turn architecture. The document says both.
- **The Claude credentials are separate** and are set up the same way: read from the environment or the secret store, never written into any repository.
- **The script verifies before continuing**: `gh auth status` and a real push to a scratch branch it then deletes. An authentication problem found at step one costs a minute; the same problem found at the first merge train costs a turn and a confusing failure.

`docs/orchestrator-setup.md` covers, in order:

- **What the machine must already have**: an operating system, git, network access, and credentials. Which credentials, what they need to reach, and how they are supplied.
- **Clone the meta repository**, then the three repositories inside it, in that order, with the exact commands and the branch each is cloned at.
- **Install the toolchain**, at the versions the prototypes pinned: mise, Zig, Bun, Node if needed, and `what-changed` on the PATH.
- **Install the system dependencies** it needs to run the work it does locally: build tools, the C library dependencies, the S3 emulator, and GTK4, WebKitGTK 6.0 and `xvfb` if the Linux application suite is to run there rather than only in the workflow.
- **Prove it works before taking a turn**: build the stub repository, run `test:everything`, and run one smoke suite. An orchestrator that cannot do those is not ready, and finding that out now is much cheaper than finding it out through a package that fails for reasons of its own.
- **How to run Claude here**: the exact command that starts a turn, headless, from the meta repository root, with the orchestrator goal as its prompt. The command to start the first turn, the command to resume after any stop, and the fact that they are the same command. How the turns are scheduled under whichever architecture was chosen. How to stop everything, and how to tell whether it is running.

### Goals are per role, and subagents do not get the orchestrator's

**The orchestrator's goal is to drive the port to parity and keep the loop turning.** Every subagent has a narrower goal, and **none of them is told the orchestrator's**, because an agent that believes its job is to advance the port will advance it at the expense of the thing it was actually asked to do. An implementer that knows the port is behind will skip a test to make progress. A reviewer that knows a package is blocking the queue will pass it. The separation is what makes the review adversarial rather than collegial.

The goals, each given to that role and no other:

- **Orchestrator**: drive the port to parity. Keep the loop turning, keep the queues moving, keep `summary.md` true, recover whatever broke, and never let work come to rest.
- **Plan author**: produce a plan for this one package that another agent could implement without asking anything, faithful to what the old repository does.
- **Plan checker**: find everything wrong with this plan. Nothing about implementing it, nothing about schedule.
- **Implementer**: implement this plan exactly, port faithfully from the named old files, prove it with tests you ran. Not "make progress", not "get this package merged".
- **Reviewer**: find every way this fails the plan, the comparison with the TypeScript, and the repository rules. Reject it if it does. Nothing about how long the package has taken or what it is holding up.
- **Merge train**: land these reviewed packages on main without breaking it, and identify precisely which one breaks it if anything does.

**The shared Goals section in `CLAUDE.md` is a different thing and stays.** That is what the port is for: parity, determinism, zero flakes, mirroring the TypeScript. Every agent needs those, because they are what "done properly" means. What must not leak is the operational goal of advancing the port, which belongs to the orchestrator alone. Keep them apart: project goals in `CLAUDE.md`, role goals in the prompt each agent is spawned with.

**It is kept true by being followed.** Every environment failure the port hits is a defect in this document as much as in the machine, and the fix goes here at the same time. Every new dependency a package introduces is added here in the same commit that introduces it, and the review checks that it was.

**Moving the orchestrator to another machine** is cloning the meta repository and following that document. Nothing else, because all state is in the repository rather than on a machine. If that turns out not to be true, the setup document is wrong and fixing it is the first job.

## Phase 0: setup and structure

Everything that has to exist before any porting starts, and nothing else. No Zig, no application code, no ported package. This phase is words, structure and scaffolding, and it ends by stopping.

**0a. The meta repository.** Create `psi-zig-port-orchestrator`, private. Inside it: clone `photosphere-old` at the `mobile` branch as a read-only reference, and create `photosphere-zig`, private, with an empty main branch. Write the meta repository's own `CLAUDE.md`, which **opens with the Goals section from this plan, copied across as its first primary section**, before any rule, so that every agent that reads the file knows what the work is for before it is told how to do it. Then the recording rules, the commit and push cadence, the concurrency rules below, and the rule that `photosphere-old` is never written to. Write `README.md` as described below, with the ASCII tree in it. Create the queue directories, the empty journal, `docs/decisions/`, `docs/lessons/`, the interventions directory, the flakiness directory, `docs/commit-template.md`, and `summary.yaml` with every phase, every numbered step of phases 0 to 5, every package and every prototype, all unticked, plus the short `summary.md` rendered from it. Write `docs/prototypes.md` with the ten briefs copied from the plan and every finding section empty. Write `scripts/setup-orchestrator.sh`, `docs/orchestrator-setup.md` and `docs/bootstrapping.md`, which together bring a fresh machine up as the port orchestrator from nothing and say how to restart the port after any failure. That script is the only executable this repository holds; everything else here is words, structure and records.

**0b. The stub new repository.** `photosphere-zig` gets its skeleton and nothing more: `mise.toml`, `package.json`, `build.zig`, `app.zon`, the directory layout, a `test:everything` that runs and reports what it found while there is almost nothing to run, `what-changed` and its configuration, the git hooks installed, and the release workflow copied over with everything not yet implemented commented out. It compiles, its tests pass, and it does nothing else. The point is that the machinery around the first package exists before the first package does.

**0c. The rules and the documentation set.** `photosphere-zig`'s `CLAUDE.md` and its entire documentation set, as detailed below. This is the part that everything else inherits.

**0d. Hand over to the meta repository.** The bootstrap session's last act is to make itself unnecessary: everything is pushed, `summary.yaml` says phase 0 is complete and phase 1 is next, and `summary.md` is rendered from it, and the journal records that the port now runs from the meta repository. **From this point nothing runs in the old repository or in the bootstrap session.** Every later turn starts by cloning or opening the meta repository and reading `summary.yaml`, including the very next one.

**Then stop.** The human reads the meta repository's structure, the stub repository, the rules and the documentation, and accepts or changes them. Nothing proceeds until that acceptance is recorded in the journal. This is the cheapest possible moment to find out the structure is wrong, and the most expensive thing to change once packages are built on it.

### The documentation set written in phase 0

**1. Write `CLAUDE.md` and the entire documentation set, and then stop and wait.**

No code, no build files, no manifest, no toolchain pin. Words only. Nothing else is written until the human has read all of it and said it is acceptable, and the rest of the plan does not start while it is outstanding. This is the cheapest place in the whole port to find out that the structure or the rules are wrong, and the most expensive thing to change once forty work packages have been built on top of it.

**The project map is the centrepiece.** `docs/project-structure.md` is a tree of the repository as it will exist when the port is finished: every directory, every significant file, and one line each saying what it holds and why it is there. It covers the Zig core module by module, the application host, the CLI, the frontend, all four test trees, the build and manifest files, and the automation directory. Where a directory corresponds to something in the old repository, the line names it, so the map doubles as the porting index. The current repository has no document like this, which is part of why this one starts with it.

The rest of the set, all written in step 1 and all reviewed together:

- `README.md`: what the project is, what it runs on, and how to build and run it.
- `docs/development.md`: the day to day loop, the toolchain, the Bun scripts, and an index of every other document.
- `docs/testing/README.md`: the four kinds of test (Zig unit, TypeScript unit, CLI smoke, application smoke), how to run each, how the harness allocates ports and directories, and what parallel safety requires of a new test.
- `docs/architecture.md`: the three channels between the frontend and Zig, the threading rule, where state lives, and how a request travels from a click to storage and back. Written from the probe repository's working code and from the SDK's source, not from the SDK's documentation.
- `docs/background-tasks.md`: what a task handler is now, the single registration site, and how to add one.
- `docs/zig-conventions.md`: the two writing rules in full, with worked examples of a TypeScript file and its Zig counterpart side by side, the divergence document's format, and the conventions taken from `what-changed`.
- `docs/how-it-works.md`: the internals, in the manner of `what-changed`'s document of the same name.
- `docs/performance.md`: what an operation costs and the budgets the performance tests enforce.
- `docs/porting.md`: the work package contract, the writing rules and the implementation and review loop. It carries no file-by-file mapping: which old file became which new one is stated in each package's own plan, where it is written once by the agent that has both open, rather than in a central list that would have to be kept in step with forty packages.
- `docs/building-and-packaging.md`: per platform requirements, the system libraries, packaging, and the release layout.
- `docs/mobile.md`: the Android and iOS toolchains, what the SDK generates, and the pinned Apple environment.
- `docs/git-hooks.md`: what the hook runs and why it is never bypassed.
- `THIRD-PARTY-NOTICES.md`: started now with the SDK and the C libraries, extended as each lands.

Documents written before the code they describe will contain claims that turn out to be wrong. That is acceptable and expected: they are a specification at this point, and each work package that contradicts one has to correct it as part of its own review. What is not acceptable is a document that describes something as working when nobody has run it, so every claim about behaviour in the step 1 set is written as intent rather than as fact, and the prototype findings taken in during phase 3 are what convert them.

**The `CLAUDE.md`** opens with the Goals section from this plan, copied across word for word as its first primary section, the same as the meta repository's does. Then it starts from the existing `CLAUDE.md` in the old repository: keep everything that is about how the human works and what they will not tolerate, drop everything that is about Electron, Capacitor and the embedded JavaScript engines, and add what Zig and Vercel Native need. It has to cover at least:

- **Platforms and apps.** One application shell across Windows, Linux, macOS, Android and iOS, plus a command line tool on the three desktop platforms.
- **Languages.** Zig, TypeScript (frontend and host-side test harness only) and shell script. Nothing else, with the same explicit ban on Python, Perl, Ruby and Go, and the same rule that a shell script contains shell and never an embedded interpreter.
- **Bun.** Bun runs the workspace, every script, the frontend bundle, the TypeScript tests and the typecheck. Never a bare `bun`, `node` or `zig`: every invocation goes through `mise exec --` so the pinned versions are the ones that run. Never invoke a shell script directly when it has a `bun run` name. If the Vercel Native CLI turns out to need Node, that is the only thing Node is for and the rule says so by name.
- **The two writing rules above**, in full, because they are the two things a review subagent checks that nothing else can check for it.
- **The testing rules**, carried over unchanged in substance: never a fake test, never a test that has not been watched fail, never make a test pass by faking the thing under test, run every test you write, and never report a compile as evidence of behaviour.
- **The parallel-safety rules**, carried over unchanged: no fixed port, no fixed path, no machine-wide name, every started process's pid recorded at the moment it starts, never kill by matching a command line, and every suite has to survive running beside another copy of itself. The human runs several worktrees at once and the orchestrator in this plan runs several agents at once, so this matters more here than it did before.
- **The git rules**, carried over unchanged: no destructive git without an explicit instruction, never commit with verification disabled, never modify the hook or its scripts, and never assume the working tree is as you left it.
- **Zig specifics**: `mise exec -- zig ...` for every invocation, every allocating function takes `allocator: std.mem.Allocator` first, `std.testing.allocator` in every test so a leak fails it, a `std.testing.checkAllAllocationFailures` test for anything that can fail to allocate, `ReleaseSafe` as a second test pass, Valgrind as a third where C libraries are linked, and errors as error sets rather than exceptions.
- **The determinism rules in full**, from the section of that name: pure where possible, every effect passed in, no globals, side effects minimised and named, and the named list of banned sources of nondeterminism. Plus the precedence rule: determinism outranks mirroring the TypeScript, and where they conflict determinism wins and the divergence is recorded.
- **The flakiness rules**, starting empty and growing one rule per flake ever found, each one written so an agent can follow it before writing code rather than after.
- **The parallel-safety rules**, and the requirement that every new test is proven parallel-safe rather than assumed to be.
- **The failure rules**, carried over unchanged: all failures noisy, no stub that pretends to work, no silent no-op, and a missing capability throws and names itself.
- **The library rules**, carried over and adjusted: no hand-written wire protocol, request signing or vendor SDK, with the Zig standard library counted as a maintained library for what ships in it (`std.http`, `std.crypto`, `std.net`, `std.compress`) and anything outside it requiring a real vendor library.
- **The reference implementation.** `what-changed` is how Zig is written here: read it and its commit history before writing any, and follow its conventions on structure, testing against real files rather than mocks, smoke tests driving the built binary, named constants carrying their reason, and error sets split where the caller treats them differently.
- **The autonomy contract**: what a work package is, what an implementation agent may and may not do, what a review agent checks, and the escalation rule when they cannot agree. Role goals are not in here: they are given per agent at spawn, and no agent but the orchestrator is told the port's operational goal.
- **Documentation and comment rules**, carried over unchanged, including the ban on em dashes, on `---` separators, on hard-wrapped prose, on the words this repository bans, and on machine-specific absolute paths in anything checked in.

## Phase 1: stand up the port orchestrator

Nothing here is about the port. It is about having a machine that can run it, and it is a phase of its own because everything after it assumes a working orchestrator and because the cost of discovering otherwise later is a package that fails for reasons that are not its own.

**1a. Provision the environment.** Under the chosen architecture that means creating the cloud environment: attach the three repositories the port reads and writes, set the network allowlist to cover the toolchain and the C dependencies, and make `scripts/setup-orchestrator.sh` the environment's setup script so it runs once and is then snapshotted. Under the fallback it means running that same script on a droplet. Either way the script does the same work: authenticate git and `gh`, clone what is needed, install `photosphere-zig`'s git hooks, and install the pinned toolchain and system dependencies.

**1b. Prove it before trusting it.** Build the stub repository, run `test:everything`, run one smoke suite, make one commit and push to a scratch branch, and open and merge a throwaway pull request, since that is how merges will land. Measure disk and peak memory while doing it, against the 30 GB and 16 GB ceilings. Every one of those has to pass. A failure here is a defect in the setup script or the environment configuration, fixed there rather than by hand, so the next session does not hit it. A resource ceiling that cannot be lived within is the trigger for the fallback.

**1c. Take one turn and stop.** The first turn writes the heartbeat, reads the board, and starts phase 2 by creating the first prototype repository. That proves the loop runs end to end before anything depends on it.

**1d. Record what the machine actually needed.** Anything the setup script did not cover, anything installed by hand, anything that failed first time: into `docs/orchestrator-setup.md` and the script, in the same commit. The second orchestrator machine is built from a document rather than from somebody's memory of building the first.

**While the prototypes run**, the loop also writes and checks the plans for packages 10 to 20, which need no prototype result and fill the queue for when the baseline is pinned.

## Phase 2: build the prototypes

The prototypes are driven from the meta repository, by the orchestrator, in the same environment the port will use. That makes this phase two things at once: the answers to the ten questions, and the first real trial of cloud sessions before anything important depends on them.

**Each prototype is its own repository**, created by the orchestrator, throwaway, and linked from `docs/prototypes.md`. Notes, findings and everything learned go in the meta repository, not in the prototype repositories, which are code only.

**The loop for a prototype**, which is the same loop the port uses with the slow half pushed out:

1. A session writes the code and runs whatever it can locally: Linux builds, Zig, headless tests.
2. It pushes. A workflow in that prototype's repository runs the platform-specific half on `macos-latest`, `windows-latest` or `ubuntu-latest`.
3. It reads the run result with `gh` and iterates.

Commit noise does not matter here. These repositories are thrown away, so pushing fifty times to get a Windows build working is the normal way to work rather than something to avoid.

**What runs where:**

- **Entirely in a session**: P8 (concurrency under Zig 0.16), P9 (data and wire compatibility), P10 (the loop itself, which is this phase).
- **Session plus a Linux workflow job**: the Linux halves of P1, P4 and P5, plus P3, P6 and P7's Android halves, since GitHub's Linux runners have KVM and can boot an emulator.
- **Session plus a macOS workflow job**: the iOS cross-compile in P4, the iOS simulator halves of P6 and P7, and the macOS parts of P1 and P5.
- **Session plus a Windows workflow job**: the Windows parts of P1 and P5.
- **Needs a Mac that the port can reach**: **P2 only**. Its whole question is whether the generated Xcode project builds under Xcode 14.2, and a runner image with a newer Xcode answers a different question. Check which Xcode versions the available macOS images carry before assuming; if none has 14.2, this one is driven through Remote Control on the human's Mac, or by the human directly.

**What this phase proves about the environment**, recorded as findings in their own right and feeding the architecture decision: whether sessions are available and stable enough, what the network allowlist has to contain, whether disk and memory hold a real build, how long sessions last, how many run at once, whether the push and pull request paths work, and what it costs. If cloud sessions cannot carry the prototypes, they will not carry the port, and the fallback to a droplet is taken here rather than after the port has started.

## Phase 3: intake of the prototype findings

The prototypes are not this plan's work. They are built separately, and what arrives here is a set of repositories and findings. This phase is what the port does with them: read them, record what they settled, and act on what they changed. It is short by design, and it is the last point at which the port is cheap to redirect.

**2. Read the prototype repositories, complete `docs/prototypes.md`, and write the findings into the new repository.** Each prototype's section gets its repository link and its finding: what it proved, what it refused to do, and every version, system package and command that came out of it. Then those findings are copied into the documents that will actually be read while building, because a finding filed only in `prototypes.md` is a finding nobody working on a package will see.

- Toolchain and versions, into `mise.toml` and `docs/development.md`: the Zig version, the exact SDK version, the Bun version, whether Node is needed and for which commands, and the system packages each platform requires.
- The build arrangement, into `build.zig` and `docs/building-and-packaging.md`: whether the build is ejected, how the frontend is bundled, how the development loop works, and what the packaging commands are per platform.
- The platform picture, into `docs/mobile.md` and `docs/building-and-packaging.md`: which platforms build, which need something the port does not yet have, and what each one needs from the user's machine at runtime.
- The C dependencies, into `build.zig.zon` and `THIRD-PARTY-NOTICES.md`: every library pinned by exact tag and content hash, never a branch or a floating reference, so a swapped upstream artefact fails a hash check rather than being fetched silently, with its licence and the advisory feed to check before each release.
- The architecture, into `docs/architecture.md` and `docs/how-it-works.md`: the threading rule, the three channels, the concurrency and cancellation model, and the media path.
- Anything the prototypes could not do, into the plan itself: a package that cannot be built the way this plan assumes gets its entry rewritten here before it is specified, not when an agent reaches it.

**3. Act on whatever the findings changed.** A prototype that came back negative moves work rather than removing it: a platform ships later, a dependency is swapped, a capability becomes a package of its own, or a requirement is raised. Make those changes to the work package list in this document, with the reason, and put the changed list in front of the human before phase 4 starts. Do not carry an assumption forward on the grounds that the plan already said it.

**4. Confirm the two writing rules survived contact with real code.** The prototypes are the first real Zig written against this SDK. If the rules made something impossible or absurd there, amend them now, in `CLAUDE.md` and `docs/zig-conventions.md`, and say what forced the change. Rules amended after forty packages are written are not rules.

**5. Pin the baseline.** The versions, the system requirements and the decisions from steps 2 to 4 are the starting state of the port. Everything after this treats them as fixed, and a change to any of them is its own work package with the full suite behind it.

## Phase 4: the walking skeleton

**6. The repository skeleton and the toolchain.** `mise.toml` pinning Zig and Bun (and Node only if P1 found it necessary), an ejected `build.zig` on P1's, `app.zon`, the Bun workspace with `@native-sdk/cli` pinned to the exact version P1 used, the frontend directory with the carried-over React UI building to a dist through whichever bundler P1 settled on, and a `tests/` tree. One Bun script builds everything, one runs every Zig test in all three passes, one runs the TypeScript tests, and one runs a named smoke suite. The script names match the current repository's wherever the thing they do is the same. `test:everything`, `what-changed`, the git hooks and the copied release workflow are all set up here, in this step, so that the very first work package is tested the way every later one will be, on every platform, from its own branch.

This is also the step that reconciles the repository against `docs/project-structure.md` from step 1. Where the skeleton has to differ from the map, the map is corrected in the same commit and the difference is called out, so the document the human approved does not quietly stop being true on the first day.

**7. The test harness and the operational scripts, ported before the thing they test.** Everything in "The operational tooling comes across, all of it" lands here or has a named work package that lands it, and the step 1 documentation lists each one with its new name. Nothing from that section waits until the end. Bring across `apps/smoke-tests/lib/runner.sh`, the control bridge, the process control library and the temp directory allocator, because they already solve the hard parts (per-test temporary directories, OS-assigned ports, recorded pids, process group cleanup, timeouts, parallel safety) and because both the desktop and the mobile suites in the current repository already drive the application through the same control bridge and the same shared test driver inside the UI. That is what makes the deduplication in step 9 possible rather than aspirational.

**8. The walking skeleton, end to end.** The real application shell: the real React UI, loaded from the embedded dist, talking to a real Zig host over the bridge, with the control bridge attached in test mode. One smoke test launches it, waits for ready, navigates, and asserts the page reached a known state, on Linux, Android and iOS.

Nothing else starts until this passes on all three. If it cannot get every platform green, the approach does not work, and that is worth knowing now rather than after fifteen packages.

**9. Fix the smoke test parity target.** The current repository has 34 UI smoke tests under `apps/desktop/smoke-tests/` and 43 under `apps/smoke-tests/tests/`. By name they share 27, with 7 desktop-only and 16 mobile-only, so the deduplicated union is 50. That number is arithmetic on directory names and is the starting point, not the answer: go through them pair by pair, confirm that a shared name is the same test rather than two different tests that happen to be numbered alike, and produce a written list of the deduplicated suite with, for each test, which platforms it runs on and why any platform is excluded. The command line suites do not dedupe: the eighty numbered tests plus the encrypted, LAN share, hash cache, sync and write lock suites all come across as they are.

## Phase 5: the shakedown

One package, ported end to end, by the real machinery, with nothing running beside it. The purpose is not the package. It is to find out what is wrong with the system while only one package's worth of work is at stake.

**The package is `fuzzy-match`** (package 12). Forty-seven lines, two functions, an existing Jest suite to port case for case, and real smoke evidence because the CLI reaches it. It is small enough that any failure is a failure of the system rather than of the work, and large enough to touch every stage. If it needs something small from `utils`, the plan takes only that.

It goes through every part of the machinery, with none of it skipped because the package is small:

- A plan written by one agent with `/plan:create`, checked by a different one with `/plan:check`, fixed with `/plan:fix`, and rechecked until clean.
- The package enters `todo/`, an implementation agent takes it in its own worktree, commits, pushes, and its branch is tested by the release workflow on every platform.
- A review agent re-runs everything itself, compares against the TypeScript on all five parts, and rejects it at least once **on purpose**, so the rejection path and the second implementation pass are both exercised rather than assumed.
- A merge train of one runs, `bun run test:everything -- --force` passes in the merge worktree, it lands on main, the worktree and branch are deleted, the parity ledger rows are updated.
- The agent records, the journal entries, the evidence directories and any decision files are all written and pushed as it happens.
- The system is deliberately interrupted mid-package and resumed, because resume is the one path that has to work and will otherwise be first exercised during a real outage.
- An agent is deliberately wedged so the next turn notices it has stopped moving, kills it and restarts it.

**Then it stops again.** The human reads what happened: the journal, the evidence, the review's findings, the ledger, and the cost. What was clumsy gets fixed in the system, not worked around, and the fix is recorded as a decision file.

**Iterate one package at a time until nothing needs changing.** If the shakedown exposed problems, fix them and run a second package the same way, still alone. Repeat until a package goes from plan to merged without the system needing a change. Only then does phase 6 start. A system that needed a fix on its last single-package run is not ready to run five at once, because every problem multiplies.

**Exit criteria for phase 5**, all of which have to hold on the same run:

- A package went plan to merged with no change to the machinery and no human intervention except the checkpoint.
- The review rejected at least once and the rejection round worked.
- An interruption and a resume happened and cost one step.
- A wedged agent was noticed, killed and recovered without anything being built to do it.
- The parity ledger, journal, decisions and evidence are complete enough that the human can reconstruct the whole run without asking anything.
- The release workflow ran green on every platform for that branch, with no job needing a rerun.
- `find-flakey-tests` on the ladder at ten runs a rung and `check-parallel-tests` with every suite both passed, run by the review agent rather than by the implementer.
- A flake was deliberately introduced, caught by those two, fixed, logged in `docs/flakiness/`, and the rule it produced added to `CLAUDE.md`. The flakiness machinery has to be exercised before it is depended on, exactly like the rejection path and the resume path.

## Phase 6: the port, as work packages

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
| 46b | The release workflow: every remaining commented job restored, old and new diffed side by side, and the mapping recorded | all | Old and new read as an almost one-to-one mapping; every job accounted for as carried over, changed with a reason, or removed with a reason |
| 47 | Documentation reconciliation: every document from step 1 checked against what was built, the project map updated to the tree as it exists, third party notices completed with every linked C library and its licence, and the `// Port of ...` header lines removed now that the correspondence has served its purpose | all | The project map matches the repository file for file; no document describes intent that was never built; no comment points at a repository the reader cannot open |

Two things about the command line packages, because they are five entries in the table and one decision underneath:

- **The `commander` port already exists.** `what-changed`'s `src/lib/commander.zig` is the subset of `commander` that a command line tool uses, in Zig, with the error wording and help layout reproduced exactly because its smoke tests assert on them. Photosphere's CLI is written against `commander` as well. Package 25 lifts that file, extends it to whatever Photosphere's command line uses that `what-changed`'s does not, and extends the deliberate-omission list at the top of the file in the same edit. It does not start again.
- **The CLI layout follows the same tool**: `src/main.zig`, one file per command under `src/cmd/`, shared code under `src/lib/`, tests in the files they test. The smoke suites drive the built executable rather than the source, which is the convention that tool adopted for the reason that what ships gets tested rather than trusted.

Not ported, for the same reasons as before: the Model Context Protocol integration, which has no Zig equivalent and stays TypeScript in whatever form the shell can host, and the React UI itself.

## The meta repository

Two repositories under one meta repository, with the commands that drive them:

```
psi-zig-port-orchestrator/
  README.md               what this is, how it works, how to interact with it
  CLAUDE.md               Goals first, then the rules for working in this repository
  summary.yaml            the state of the port as data, orchestrator-written
  summary.md              rendered from summary.yaml, never edited directly
  .gitignore              ignores the three cloned repositories below
  photosphere-old/        the existing TypeScript repository, cloned, gitignored, never written to
  photosphere-zig/        the Zig and Vercel Native repository being built, cloned, gitignored
  .claude/
    settings.json         permissions set to bypass, so agents work without prompting
    commands/port/        the commands that drive the loop
  scripts/
    setup-orchestrator.sh the one script: auth, clone, bootstrap, toolchain, verify
  docs/
    plan.md               this plan, the master copy
    prototypes.md         the ten prototypes, their repos, and their findings
    bootstrapping.md      how to start the port, and how to restart it after anything
    orchestrator-setup.md what that script does, what it needs, how to fix it
    commit-template.md    the one commit format, read at commit time by every agent
    decisions/            how the porting process changed, one timestamped file each
    lessons/              what worked and what did not, one timestamped file each
    journal/              port-level entries, one timestamped file each
    interventions/        every time a human had to step in
    flakiness/            one entry per flake: what, why, the fix, the rule it produced
    queues/               todo, in-progress, review, merge-queue, done, conflicts
      <queue>/<package>/  status.md, plan.md, journal/, evidence/, review-N/findings.md
```

### `README.md`

Written in phase 0, kept current, and aimed at a human returning after months who will not reread the plan. It covers:

- **What this repository is**: the orchestrator for an autonomous port of Photosphere from TypeScript to Zig, and what the other two repositories beside it are.
- **The goals**, in short, and a pointer to `docs/plan.md` for the whole thing.
- **The glossary**, copied from the plan, because the words are the first thing a returning reader has lost.
- **How it works**, in a few paragraphs: turns, queues, plans, implementation and review agents, merge trains, and the fact that nothing waits on a person.
- **An ASCII tree of the repository**, the one above, so the layout can be taken in at a glance rather than by listing directories.
- **How to interact with it**: where to see what is happening (`summary.md`, first line for the heartbeat), how to tell whether it is stuck, how to stop it, how to start it again, how to reverse a decision, and where to read the story of any package.
- **What it needs from a human**: the credentials, and the two checkpoints.
- **How to start it, and how to restart it when it has fallen over**, pointing at `docs/bootstrapping.md`. This is the link a returning reader needs first, so it goes near the top.

**The meta repository does not live on any particular machine.** It is cloned onto whichever machine is acting as the port orchestrator, which is a droplet or a cloud session, and it can move between them. Everything inside it is referred to by a path relative to its root, and no absolute path to anyone's home directory appears in any file in it. An orchestrator machine is set up by cloning the meta repository, cloning the three repositories inside it, and bootstrapping, in that order, from `docs/orchestrator-setup.md`.


`photosphere-old` is a fresh clone of the existing repository at its `mobile` branch, and it is **never written to**. It is opened, read and diffed against, and that is all. A fresh clone rather than a link to a working checkout, so that every runner sees the same tree and no agent can reach a human's uncommitted work.

Both new repositories, `psi-zig-port-orchestrator` and `photosphere-zig`, are private.

`docs/` in the meta repository is where the port's own history lives, and it is the reason the meta repository exists at all rather than putting everything in the new repository. Plans about porting are not documentation of the ported product, and mixing them makes both worse.

### Plans, not specifications

Every package of work is a **plan**, written with `/plan:create`, checked with `/plan:check`, fixed with `/plan:fix`, and implemented with `/plan:imp`. Plans live in the meta repository under `docs/plans/new/` and move to `docs/plans/done/` when their package has merged. The skill's format is the format: overview, issues, steps, unit tests, smoke tests, verify, notes.

On top of what the skill asks for, a port plan names:

- **Source of truth**: the exact files in `photosphere-old/` being ported, by path, with line counts. The implementing agent reads all of them. Where a probe repository already prototypes the feature, its files are named too and read first.
- **Files to create** in `photosphere-zig/`, by path, so that two plans can be checked for overlap before either starts.
- **Public interface**: the functions, structs and vtables the package exposes, with signatures, so the next plan can be written before this one is built.
- **Divergences allowed**: the specific places this package may depart from the TypeScript, with reasons. Anything else is a divergence to raise rather than take.
- **Dependencies**: the packages that must have merged first.

A plan that cannot be written in this form covers too much and gets split with `/plan:break` before anyone starts on it.

### The measure of success is closeness to the TypeScript

Every package is judged by comparison with the thing it replaces, not by whether it works. Working is the floor. The comparison is the standard, and it is what the review checks, in five parts:

1. **Behaviour**: the same inputs produce the same outputs, the same errors, the same exit codes and the same bytes on disk.
2. **Code**: file for file, function for function, in the same order, with the same control flow, so a human can read the two side by side. This is rule 1, and it is what makes the other four checkable at all.
3. **Unit tests**: the Jest suite ported case for case, with the same names describing the same behaviour, plus the leak and allocation-failure coverage TypeScript never needed.
4. **Smoke tests**: the same suites, the same test names, the same assertions, deduplicated only where the desktop and mobile versions did the same job.
5. **Documentation**: the same explanations in the same places, adjusted for the new language rather than rewritten.

A package that does the job differently, tests it differently, or explains it differently has failed even if everything is green, because the value of this port is that the two can be checked against each other. Where the closeness cannot be had, the plan says so in advance and the divergence document records it.

### Recording what happened, as it happens

The meta repository keeps a journal, and it is a deliverable rather than a byproduct. It is what a write-up of this work will be built from later, so it has to be detailed enough that nobody has to reconstruct anything from memory.

**The journal lives with the package**, in a `journal/` directory inside the package's own directory, so it travels with everything else into `docs/queues/done/` and reading a package means reading one place. Entries about the port as a whole rather than about a package (the cold start, a process change, an environment repair, a turn that did nothing) go in `docs/journal/`, which is the same arrangement one level up.

**Every record file in the port is named the same way**, whether it is a journal entry, a lesson, a decision, a flake or an intervention:

```
<year>-<month>-<day>-<hour>-<min>-<sec>-<agent type>-<agent id>-<short name>.md
<package>/journal/2026-08-14-14-30-52-implement-a7f3-pass2.md
```

- **UTC, always**, and stated as UTC in the entry. Agents run in different places, and one local timestamp makes the whole listing sort wrongly.
- **Every field fixed width and zero padded**, so a plain alphabetical listing is chronological. That is the point of the format: `ls` is the index, and nothing has to be built to read the order.
- **Milliseconds only when needed**, as another field after the seconds. They break a tie when two files land in the same second, so most names will not carry them. A name that collides with an existing file is the signal to add them.
- **Then the agent type**, so it is obvious at a glance whether a run was an implementation, a review, a merge or a plan.
- **Then the agent id**, which ties the entry to that agent's record.
- **Then a kebab-case short name**, or the pass where there is one, so the listing can be read without opening anything.

An entry says what was attempted, what happened, what failed and why, how long it took and what it cost. Only the agent that created a file ever writes it.
- `docs/decisions/` is **the log of how the porting process itself changed**, and nothing else. Every time the human gives feedback that changes how the port is run, or the system is adjusted because something did not work, an entry is appended: the date, what changed, why, what it replaced, and what prompted it. This is the record of the process evolving, which is exactly what will be impossible to reconstruct afterwards and is the most interesting part of a write-up. It is not for decisions about the code: those belong to the package that made them.
- `docs/lessons/` is what worked and what did not, one timestamped file per lesson, written by whoever noticed it. It is for observations that are not yet decisions: a pattern seen across several packages, an approach that went better or worse than expected, something that would be done differently next time. Each entry says what was observed and over how many occasions, what it suggests, and whether it has been acted on. When a lesson causes an actual change, the `docs/decisions/` entry for that change points back at it. A directory rather than a file for the same reason the journal is one: several agents run at once, and a shared file conflicts on every push and loses entries when a conflict is resolved badly.
- **A process change that gets reversed is not edited out.** The original entry stays and the reversal is appended, naming what changed and why. The pairs are the point: a process that was tried, found wanting and replaced is worth more than a process that appears to have been right from the start.

**The first entry in `docs/decisions/` records the decisions already taken**, before the port starts, because they were made while this plan was written and would otherwise be lost. It is written at the cold start, dated to the day the port begins, and says that these predate the log:

- **A new repository rather than porting in place.** The earlier version of this plan replaced packages inside the existing repository; this one does not.
- **A meta repository over the top**, holding the process, with `photosphere-old` read-only and `photosphere-zig` for the port.
- **Vercel Native replaces both Electron and Capacitor**, one application for all five platforms.
- **Bun runs everything that is not Zig**: workspace, scripts, bundling, TypeScript tests, typecheck.
- **The Zig mirrors the TypeScript file for file and function for function**, so the two can be read side by side.
- **Determinism outranks that mirroring.** Where they conflict, determinism wins and the divergence is recorded.
- **Pure and functional, no mutable globals in core code**, every effect passed in.
- **No comment ever justifies anything by pointing at the TypeScript**, and the port headers are removed when parity is reached.
- **The prototypes belong to the human and are built outside this plan.** The port takes their findings as input.
- **Plans, not specifications**, written with the plan commands in `.claude/commands/port/`, by one agent and checked by another.
- **Success is measured by closeness to the TypeScript** on behaviour, code, unit tests, smoke tests and documentation. Working is the floor, not the standard.
- **Parity is counted per package**, in each package's own record, with no central ledger to maintain.
- **The queues are the state.** No JSON state file, and the git history of the moves is the audit log.
- **There is no blocked queue and nothing waits on a human.** A failed package goes to the back of `todo/` and comes back one rung up the escalation ladder.
- **Decisions about code are taken autonomously and recorded**, never queued for a person.
- **No tooling is built for the port.** Every helper script that was proposed became a rule an agent follows.
- **`summary.yaml` is the only aggregating file**, edited surgically by the orchestrator alone, with a short `summary.md` rendered from it for a human to read.
- **No index file aggregates anything across packages.** A package's record lives with the package.
- **Journals are per package, one timestamped file per entry, UTC**, so a listing sorts by time and two agents cannot collide.
- **`docs/decisions/` is for process changes only**, written by the orchestrator.
- **One commit template**, in the meta repository, used by every agent for every commit.
- **Review findings are one file per pass**, carrying what passed, what earlier passes tried and disproved, and the ladder rung.
- **A single merge train at a time**, in its own worktree, running the full suite and bisecting on failure.
- **Zero flaky tests from the first commit**: the flake hunter at ten runs a rung and the parallel check over every suite, run by every review; five sequential green release workflow runs to close a flake; a flakiness log whose every entry produces a rule in `CLAUDE.md`.
- **The release workflow is carried over intact** and adapted minimally, with unimplemented jobs commented out rather than deleted.
- **The operational scripts all come across**, and none may be deleted or replaced without the human saying so.
- **Eight phases with two checkpoints**: setup, orchestrator, prototypes, intake, skeleton, shakedown, the port, then the parity audit, which loops back to the port until it finds nothing. Phase 0 and phase 5 stop for a human.
- **The prototypes are built by the orchestrator rather than by the human**, in cloud sessions with workflows for the platforms a session lacks, which also makes them the trial of the environment before the port depends on it.
- **The bootstrap is done by an agent.** The only human action is supplying the credentials the scheduled turns run under.
- **The orchestrator and its agents run as Claude Code cloud sessions**, with a long-lived droplet kept as the fallback if the preview, the resource limits or the push restriction make that unworkable. GitHub Actions runs the multi-platform testing either way.
- **Everything is committed and pushed as it happens**, never batched.
- `docs/interventions/` records every time the human had to step in: what went wrong, what they did, and what would have had to be true for it not to happen.
- The last findings file of a package carries its wrap-up: what was built, what each review pass caught, how many rounds it took, and anything surprising. Written once, at the end, in a file that was being written anyway, rather than as a separate note somebody has to keep in step.

**Every agent writes to the journal, and this goes in `CLAUDE.md`.** An implementation agent records what it built and what fought back. A review agent records what it rejected and why. The merge train records what it merged and what it bisected. An agent that finishes without recording anything has not finished. The rule to state in `CLAUDE.md` is that notes are written at the time, in the same commit as the work, never reconstructed afterwards.

### No shared file is ever written by two agents

With several agents running at once, any file more than one of them writes will be corrupted or will lose entries, and git makes it worse rather than better: two agents appending to the same file produce a conflict on every push, and a conflict resolved badly silently drops somebody's entry. The answer is structural, not procedural, and it is a rule rather than a convention.

**Nothing shared is appended to. Everything shared is a directory of single-writer files.**

- **The journal is a directory**, not a file, both inside each package and at the top level. Each entry is its own file, named as above so two agents cannot collide and the listing sorts by time. Only the agent that created an entry writes it. Nothing appends to a day's file, because there is no day's file.
- **Decisions are a directory too**, with one file per decision, and reversals are new files that name what they reverse rather than edits to the original.
- **`docs/decisions/` records changes to the porting process**, in date order, appended as they happen. It is chronological rather than an index over packages, which is why it exists where a reviews index does not: each entry is written once and never revisited.
- **Only the orchestrator writes it**, because process changes come from the human's feedback to the orchestrator or from the orchestrator noticing the system is not working. A subagent never touches it. It, `summary.yaml` and the `summary.md` rendered from it are the only files in the repository written by more than one thing over the life of the port, and both have exactly one writer.
- **Decisions about code go to the package that made them**, in its plan, its findings or its journal entry, never here. Mixing the two would bury the handful of entries that matter under hundreds that do not.
- **Parity counts live per package**, in the package's own file, and are only summed into `summary.md` by the orchestrator. Two packages recording their own counts never touch the same bytes.
- **A package directory has exactly one writer at a time**, and the agent record says who it is. The orchestrator is the only exception, and only after it has killed the owner.
- **`status.md` and `plan.md` are written by the agent that owns the package**, in its stage. Nothing else edits another package's files.

**Committing concurrently needs its own care**, because a git repository has one index and one lock:

- Every commit to the meta repository stages **only the paths that agent owns**. Never `git add -A`, which sweeps up whatever another agent has half-written. This is the single most important rule in this section, because it is the one whose violation corrupts somebody else's work rather than your own.
- Because every entry is a distinct new file, rebases have nothing to conflict on. That is the property the directory-of-files design buys, and it is why it is worth the extra files.
- Agents on different runners each have their own clone, so the lock is per-clone and the remote is the meeting point. The retry on rejected push is what makes that safe.
- `photosphere-zig` has no shared-file problem at all, because each package works in its own worktree on its own branch and the only place they meet is the merge train, which is single-threaded by design.

Committing is done by hand, by the agent, following one sequence every time: pull with rebase, stage only the paths that agent owns, commit, push, and retry the pull and push if the push is rejected. There is no helper script and no lock, because the design removes the contention rather than managing it: every agent writes only files that nothing else writes, so a rebase has nothing to conflict on and a retry always succeeds.

**No process tooling is built for this port.** Not a queue mover, not a commit helper, not a summary generator, not a ledger builder, not a watchdog daemon. The single exception is `scripts/setup-orchestrator.sh`, which provisions a machine once and is not part of the loop. Every one of those would be another piece of software to write, test, debug and maintain, in a project whose entire purpose is porting something else, and its failures would be indistinguishable from the port's failures. The only executable things in this port are the ones being ported and the ones carried over from the old repository.

### The commit template

Commits are the port's most durable record, more so than the journal, because they sit against the code forever and are what somebody reads in two years when they wonder why a line is the way it is. **`docs/commit-template.md` in the meta repository is the one format**, and the meta repository's `CLAUDE.md` says that every agent uses it for every commit in both repositories. No agent writes a commit message from its own instincts.

The format follows the old repository's convention, because that is what the human already reads and writes:

- **A subject line saying what was done**, in the past tense, as a sentence: "Ported the binary serialiser to Zig", "Cut the CLI smoke tests from 3m 17s to 1m 20s". Not a conventional-commits prefix, not an imperative, not a type tag. Under about seventy characters.
- **A body of prose paragraphs**, not bullet points, explaining what changed and **why**, what was tried and rejected, and anything a reader would otherwise have to reconstruct. The old repository's commits run to several paragraphs when the change deserves it, and that is the standard rather than the exception.
- **Measurements where a claim is made about behaviour or speed**, with the conditions they were taken under. A number with no conditions attached is not evidence.
- **What was verified**, named: which suites ran, what they reported, whether the flake hunter and the parallel check were run and what they said.

On top of that, a port commit carries trailers that tie it to the process, so any commit can be traced back to its plan and its evidence without opening the meta repository:

```
Package: 13-merkle-tree
Plan: docs/plans/new/plan-13-merkle-tree.md
Pass: implementation-2
Evidence: docs/queues/review/13-merkle-tree/evidence/implementation-2/
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
```

Three rules go with it, all in `CLAUDE.md`:

- **The template is read at commit time**, not remembered. It is a file with the guidance in it, so the guidance is in front of the agent writing the message.
- **A commit never claims a check passed that the agent did not run and read.** The verification paragraph is the place this rule is most often broken and it is checked at review.
- **The subject describes what the change does, never what the plan said to do.** A commit that says "Implemented step 4" is useless to everybody who was not holding that plan at the time.

### Committing and pushing as it goes

Progress has to be visible without asking anyone, at any moment, from the remote alone.

**Every write to the meta repository is committed and pushed immediately, as part of the same action that made it.** Not batched, not left for the end of a turn, not left for the end of a session. A queue move, a journal entry, a decision, an evidence file, an agent record, a package's parity counts and an edit to `summary.md` are each pushed the moment they are written. The rule is that an agent never holds an unpushed change while it goes off to do something else, because the thing it goes off to do is exactly what might kill it.

`summary.md` is edited and pushed **every time anything it shows changes**, not once a turn. A package moving queue, a review verdict, a merged train, a parity count, a package climbing the escalation ladder: each of those is a few lines changed in place and a push. The cost is a commit; the benefit is that the remote is never out of date, so the page can be read at any moment and believed.

- The meta repository is committed and pushed as plans, journal entries, decisions and notes are written. Not batched at the end of a session.
- `photosphere-zig` is committed on the package branch and pushed as the work happens, so a branch under way is visible, then merged to main and pushed.
- Both use the verification hook, always. Neither is ever force pushed.

## Process machinery

Two things decide all of it.

**Every stage is driven by the orchestrator, beginning to end.** No stage waits on a person, there is no human review step in the pipeline, and there is nowhere for work to come to rest. A human reads what happened and can reverse a decision afterwards, but nothing pauses for them.

**The acceptance criteria are not invented, they are read out of the old repository.** The specification for this port already exists and is executable: it is `photosphere-old/`. Every plan's criteria are what the TypeScript does, what its tests assert, and what its docs say, so "is this right" is always answerable by opening the old file rather than by judgement.

### Queues are the state

The queue a package sits in **is** its status, and the git history of those moves is the audit log. No JSON state file: harder to read, easy to desynchronise, no history.

`docs/queues/` in the meta repository:

```
todo/ -> in-progress/ -> review/ -> merge-queue/ -> done/
```

plus one pen beside the pipeline:

- **`conflicts/`**, off `merge-queue/`, for a reviewed package whose commits will not replay onto a main branch that moved under it. Drained first, every turn. **Not a failure** and counts toward nothing: main moving says nothing about the package.

**There is no `blocked/` queue and no queue that waits on a person.** A package that fails goes to the **back of `todo/`**. Nothing is parked, and no part of the loop can come to rest with work outstanding.

That only works because **coming round again means coming back differently**. A package returning to `todo/` a third time with the same plan and the same approach is a loop rather than a retry. See the escalation ladder under **Failures**.

**Decisions are taken and recorded, not queued.** Where a choice arises that a human would once have made (a divergence from the TypeScript, a route change, an ambiguity in the old code), the agent decides it, records it with the alternatives rejected in its package's record, and carries on. A decision recorded and later reversed costs one package's rework; a decision deferred costs the whole loop stopping.

**The existence proof is always available.** Every feature, test and platform already works in `photosphere-old`. When something looks impossible, read how it was done there first. "This cannot be done" is only ever a statement about the current approach.

Each package is a directory that moves between queues as a unit, carrying its plan and its evidence, so nothing is ever separated from its record. Split each one into a `status.md` (id, dependencies, failure count, ladder rung, one-line description) and a `plan.md` (the full plan), so a turn can read the whole board cheaply and open only what it needs. Neither is an index over anything: both describe one package.

Work the queues in this priority order: **finish what is nearest to done before starting anything new.** `conflicts/` first, then `merge-queue/`, then `review/`, then `todo/`. Otherwise reviewed work piles up behind newly started work.

### Measuring parity

Counting merged packages flatters: forty merged sounds finished while a hundred test cases quietly never got ported. Progress is measured against the old repository instead.

**Per package, in its own file: four counts and a list.** Source files ported against the number that package covers; unit test files and cases against the old repository's count; smoke tests by name; documents. Anything deliberately not ported is listed by name with its reason. An omission with a reason is a decision; an omission without one is a mistake.

The counts come from the old repository when the plan is written, by listing the files that plan covers, and go into the plan. Established once, by the agent that already has the files open. The review checks them against what was built; the orchestrator copies the totals into `summary.md`.

The port is finished when every package's record is complete and the totals account for everything in the old repository.

### `summary.yaml`, and `summary.md` rendered from it

**`summary.yaml` is the store.** The state of the port as data: the heartbeat, the phase, the progress counts, the phases and their steps, the prototypes, the packages, what is struggling, and the decisions taken recently. It is **read, changed surgically and written back**: a status changes, a count moves, a box ticks. Never rebuilt from scratch, so an update touches a few lines and costs almost nothing.

**`summary.md` is the view**, rendered from it whenever it changes, and **never edited directly**. It is what a human opens. It is deliberately short: the heartbeat, the progress table, the phases, the prototypes, the packages, what is struggling, recent decisions. Nothing else. Every long list that could go on it belongs somewhere it is already recorded, and putting it here as well is two records to keep in step.

The rules:

- **Only the orchestrator writes either file.** Subagents never touch them; they write their own files and the orchestrator folds the outcome in at step boundaries. That is what makes it safe with several packages in flight.
- **The rendering is done by the orchestrator, not by a script.** No tooling is built for this port, and that has not changed. The view is small and the mapping is obvious, so rendering it is a minute's work at a step boundary, which is the point of keeping it small.
- **The store carries the checkboxes for phases and their steps.** That is what says where a turn resumes before any package exists: the queues track packages, and phases 0 to 5 are steps with no queue. The first unticked step is where work continues.
- **A box is ticked only when the thing is finished.** For a package that means merged to main, parity counts accounted for, unit tests ported case for case and passing, smoke tests passing at the level the old repository had them, and the release workflow green on every platform for a revision containing it. Merged is not finished. Green on Linux is not finished.
- **The plan carries no checkboxes and no status.** It is a specification and is not edited as work proceeds.
- **The queues are the truth.** Where they and the store disagree, the queues win and the store is corrected. Check this after any interruption.
- **Every check leaves a copyable result** beside its captured output: one line saying what ran, the verdict and the counts. Nothing reads a test log to update the store.

**The heartbeat is first in both files**: when, which agent, what it is doing, what it expects next, and its process id and machine. It is what says whether anything else on the page is still moving, and it is how an orchestrator that has stopped is spotted in one glance.

### Failures, and what is not one

Getting this taxonomy wrong makes the loop thrash:

- A **failure** is any setback with the work: a check fails, an agent exhausts its budget, a review rejects, a rebase cannot be resolved, post-merge checks fail on main. Record it on the package (increment the count, write a history note saying what failed and where the evidence is) and send it to the **back of `todo/`**. It always comes back; what changes is how it is approached next time.
- An **interruption** is the run being cut off from outside: a rate limit, a killed process, a dead machine. It says nothing about the package. **Record it nowhere, count it toward nothing, leave the queues as they are.** A package left mid-stage is re-driven from where it sits, not failed. Treating interruptions as failures walks untouched work up the escalation ladder for no reason.
- A **merge conflict** in the train is not a failure either, and goes to `conflicts/`.
- A **setup or environment failure** (the toolchain will not install, the orchestrator's environment is broken) is **fixed, not routed around**. The environment is code: it is `docs/orchestrator-setup.md` and the workflow files, both of which the port owns and can change. So the response is to fix the setup, record what was wrong in the journal, and put the packages it hit back in `todo/`. What remains banned is the *fake* fix: no substitute toolchain standing in for the pinned one, no skipped install, no borrowing another worktree's state, no test made to pass without the thing it tests. Repairing the environment is required; pretending it is repaired is not allowed.
- **Two or more packages failing the same stage or check in one turn is an environmental failure.** The shared cause is the environment, not the packages, so retrying the packages is wasted. Stop launching new work, fix the shared cause first, record it, and then let the affected packages come round again. Never respond by serialising what was parallel.

**The escalation ladder, since there is nowhere to park a package.** A package's failure count decides *how* it is attempted next, not whether it is. Each rung is tried before the next, and which rung a package is on is recorded on it:

1. **Retry.** The first failure is often the run rather than the work. Same plan, fresh agent, from the last checkpoint.
2. **Fix what the review named.** The second attempt addresses the findings specifically rather than reimplementing.
3. **Re-plan.** A third failure means the plan is wrong, so the plan is rewritten: `/plan:check` and `/plan:fix` on it with the failure history as input, by an agent that did not write it.
4. **Split it.** A plan that keeps failing is usually too big. Break it with `/plan:break` into pieces small enough that a failure names one thing.
5. **Go and read how the old repository did it.** Every one of these features already works in `photosphere-old`. Open the TypeScript, the tests around it, and its git history, and port the approach rather than inventing one.
6. **Change the route.** Different library, different arrangement, different order, a dependency built first. Record the decision and why the previous route was abandoned.

A package cycling on the same rung twice has not escalated, and that is itself the failure to catch. The rung, the attempt count and the reason are all in `summary.md`, so a package quietly going round forever is visible on the front page rather than buried.

**Reconciliation invariant: at the end of every turn, `in-progress/` is empty.** Any package still sitting there is a failure nobody recorded, because no agent is working it now, so the orchestrator records and routes it itself. An agent that dies cannot file its own failure, so the loop never depends on it doing so.

### Evidence, and never trusting a report

- **Confidence is not evidence.** Before any claim that a check passed: identify the exact command, run it fresh, read the full output including the exit code, confirm it supports the claim, and capture it. A previous pass passing is not this pass passing. An agent's report is not a verified result.
- **One evidence directory per pass**, numbered: `implementation-1/`, `review-1/`, `implementation-2/`, and so on, plus `merge/`. Older passes are history and are never consulted to fill a gap in a newer one.
- **The latest pass proves the whole change on its own**, not just the part it altered, and everything in it is captured fresh from that pass's commit. Evidence carried forward from an earlier pass does not prove the current code.
- **Evidence never enters `photosphere-zig`.** It lives in the package directory in the meta repository. Nothing is ever committed to the product repository to make a capture possible: no evidence switch, no capture helper, no test that exists to produce a screenshot. A commit in `photosphere-zig` contains the port and nothing else, and the review enforces that by reading the diff.
- **Every check records the same five fields**: what was verified, how, the result, the basis for it, and on failure what to change.
- **Checks run in the foreground.** Never launch a local check in the background and end the turn waiting to be woken. A stall has to become a visible failure rather than an idle wait. The one exception is a release workflow run, which is durable, attributable to a commit and readable by a later turn: waiting on one is a recorded state on the package, never an agent sitting idle.

Checks come in two kinds and they are interchangeable in the pipeline: **deterministic** ones where a command decides (compile, all three Zig test passes, unit, CLI smoke, application smoke), and **judgement** ones where an agent decides against a named rule (the five-part comparison with the TypeScript, the no-globals rule, the documentation rules). They differ only in what the evidence is: command output, or a written assessment naming the rule and the code.

### Stopping and resuming

**Resuming is a normal operation, not a recovery**, and it has to work when every agent that knew what was happening is gone. The queues say which packages are in flight; they do not say what an agent was in the middle of. That gap is what this section closes.

**Every agent writes an agent record before it does any work**, into its package's directory in the meta repository, committed and pushed immediately so it survives the machine that wrote it:

- **Type**: plan author, plan checker, plan fixer, implementer, reviewer, merge train. What kind of agent this is, because resuming means starting the same kind again.
- **Package and pass**: which package, and which numbered pass it is (`implementation-3`, `review-2`), so its evidence directory is unambiguous.
- **Branch, worktree and runner**: where the work lives and which machine it was on.
- **The plan step it is on**: the numbered step from the plan, updated as it crosses each one.
- **What is finished and what is next**, in its own words, at the level of the plan's steps.
- **How to resume it**: the exact instruction to hand its replacement.

**The record is updated at every step boundary**, not continuously and not only at the end. A step is finished when its work is committed and its record says so. That makes the last committed record the resume point, and the most a crash can cost is the step in progress.

**Every step is idempotent, because a resumed agent redoes the step it was in.** A worktree that already exists is reused rather than recreated. A commit that is already there is not made twice. An evidence directory is allocated by taking one more than the highest existing number, so a redo writes a fresh directory instead of corrupting one. A queue move that has already happened is a no-op. Nothing anywhere assumes it is running for the first time.

**Work is pushed as it happens, for a reason that is not visibility.** A runner can die and not come back. If the branch is on the remote, the package is recoverable on a different runner from the branch plus its agent record; if it only ever existed in a worktree on that machine, it is gone. The same goes for the meta repository: a queue move or a journal entry that is committed but not pushed is invisible to every other runner and lost with the disk.

**Resuming is one operation**: the orchestrator starts, reads the board, and for every package not in a terminal queue reads its latest agent record and starts an agent of that type, told which step to resume from. It does this whether it stopped cleanly, was killed, or ran out of credit an hour ago. Nothing is failed for having been interrupted, nothing is re-planned, and no package is started over from the beginning because its agent died.

**An interruption is never a failure**, which is worth repeating here because it is the rule most likely to be got wrong by an agent trying to be helpful. Running out of credit says nothing about the package. It is recorded nowhere, counts toward nothing, and moves no package down the queue. The package is re-driven from its last checkpoint, on the same rung it was already on.

**The orchestrator's own state is in the queues and the records, never in its context.** A turn reconstructs everything it needs by reading, so the loop is resumable at any point and the length of the port is not limited by how long a session lives.

### An agent that is stuck gets killed and resumed

**The rule, before any of the detail: if an agent is stuck, kill it and resume it from where it left off.** Do not diagnose it first, do not wait to see if it recovers, do not ask anyone, and do not treat it as a special case. Kill the process tree by its recorded pid, and start a fresh agent of the same type from the last checkpoint in its record. That is the whole response, and it is the same response as for a crash, because from outside they are the same thing: an agent that is not going to finish.

The rest of this section is only about how to tell that an agent is stuck, and what it means when the same one keeps getting stuck.

Resuming after a crash is the easy half. The harder half is an agent that has not crashed, is still holding its slot, and is making no progress, because nothing reports that and the loop will wait forever.

**A plain timeout is not enough on its own.** This repository has suites that legitimately take a long time, and a wall-clock limit either kills work that is progressing or is set so high it never fires. Progress is what has to be measured, and the agent record is what measures it.

**The heartbeat is the agent record.** It is written at every step boundary, so its last-updated time is a progress signal rather than a liveness signal: a process that is alive but going nowhere stops updating it. On top of the step boundaries, an agent **declares a long-running command before it starts it**, writing what it is running and how long it expects to take, and clears the declaration when it returns. That is the difference between a forty minute smoke suite and an agent that has stopped, and without it the two cannot be told apart from outside.

**Three things mark an agent as stuck**, and any one is enough:

- **No heartbeat** within its budget, with no long-running command declared. The budget is per agent type, not one number for everything.
- **A declared command overrunning its own estimate by a wide margin**, which catches a hung process, a command waiting on input that will never come, and a test suite that has deadlocked rather than failed.
- **No durable output**: no commit, no evidence file, no queue move, over a whole budget. An agent editing the same file back and forth produces nothing that survives, and that is exactly what a confused agent does.

**Repetition is its own signal, and it is a failure rather than a stall.** The record counts attempts per plan step. The same step re-entered past its cap, or the same command run repeatedly with the same failure, is an agent going in circles: it is killed, the outcome is **recorded as a failure** and routed by count, and the plan is what gets looked at, because a step an agent cannot get past twice is usually a step that is wrong.

**A first stall is not a failure; a repeat stall on the same step is.** The first time an agent is killed for making no progress, it is restarted from its last checkpoint like any interruption, because it may have been unlucky. A second stall on the same step counts as a failure and sends the package to the back of `todo/`, where it comes back one rung up the escalation ladder. A step that keeps getting agents stuck is a step that is wrong, so the ladder's answer is to re-plan or split it rather than to try it again.

**Killing is done properly or not at all.** Kill the process tree by recorded pid, never by matching a command line. That rule exists in the current repository because a name-matching kill once took down an unrelated test run on the same machine, and here there may be several agents, several worktrees and several runs on one host. Every agent's pid and process group go into its record at the moment it starts, because a process nobody wrote down cannot be killed safely.

**Queued is not stuck.** A package sitting in `todo/` or `merge-queue/` is waiting its turn, not stuck, and is left alone. What gets watched is a package in `in-progress/` or `review/` whose agent record has stopped moving.

**Watching is a job, not a daemon.** No separate watchdog process is built, because that would be tooling and it would need its own tooling to watch it. Two things do the job instead:

- **The orchestrator checks at the top of every turn.** It reads the agent records anyway to see what is in flight, so noticing that one has not moved since the last turn costs nothing extra. Anything stale it kills by the recorded pid and process group, records, and restarts from the last checkpoint.
**Telling whether the orchestrator itself is stuck, without reading anything but one line.** The orchestrator writes a heartbeat line at the top of `summary.md` every time it does anything at all: the timestamp, the turn number, what it is doing right now, and what it expects to be doing next. It is the first line on the page, so the check is: open `summary.md` on the remote and read line one. If that timestamp is older than the longest thing the orchestrator could legitimately be waiting on, and the line does not say it is waiting on that thing, it is stuck and should be killed.

That is the whole diagnosis, deliberately. It needs no log reading, no process inspection and no access to the runner. Two properties make it work: every write is pushed immediately, so the remote is never behind, and the line says what is expected next, so a long silence can be told apart from a long operation. The orchestrator's own pid and process group go in that line too, so killing it is one command on whichever runner it names.

Killing it is always safe, which is the point of the resume design: it holds no state that is not already committed, so the next turn picks up from the queues and the records. The same is true if it is killed while it is not stuck.

Neither architecture has an automatic backstop for an orchestrator that gets stuck, since both run it as a long-lived session. It stays stuck until the heartbeat is noticed, which is why the heartbeat is the first line of `summary.md` and why killing and restarting is always safe.

### The review agent edits nothing

The review agent makes no code edits and commits nothing to the product repository. Its only writes are the package's own state: moving it between queues, capturing check output to its evidence directory, and on rejection a history note and a failure increment. It never fixes what it judges, because a reviewer that fixes things is an implementer with no reviewer.

It also reviews **the diff hunk by hunk against the plan**, and any change not required to implement the plan fails the review, whatever its nature.

## The implementation and review loop

One cycle per package. The orchestrator owns the loop; the agents talk only through the worktree, the plan and the notes.

1. **Orchestrator** picks the next package whose dependencies have merged, creates a branch and a worktree in `photosphere-zig/`, and starts an implementation agent with the plan. Worktree and branch are named for the package and numbered, `wp-13-merkle-tree-1`, with the number rising if a package needs a second attempt, so it is always obvious what a worktree is for.
2. **Implementation agent** works only inside its worktree. It reads the named files in `photosphere-old/`, writes the Zig, writes the tests, runs them, and iterates until they pass. It commits with the hook enabled and pushes its branch as it goes. It writes its journal entry and a handover note saying what it built, what it ran, what passed, and what it could not do.
3. **Review agent** starts fresh in the same worktree with the plan and the handover note. It does not trust the note. It checks:
   - The five parts of the comparison above, with `photosphere-old/` open beside the new code. This is the main event, not a formality.
   - Every file the plan named exists, and nothing beyond the plan was changed.
   - No mutable global anywhere in the core, and no hidden state in a core library.
   - Every named unit test exists and would fail if the code were wrong. It breaks at least two on purpose and confirms they go red.
   - It runs the tests itself: all three Zig passes, the unit suite, and every smoke suite the plan named, on the platforms the plan named.
   - **It runs `find-flakey-tests` on the ladder at ten runs a rung, and `check-parallel-tests` with every suite included**, and both pass. No package is accepted without them, and a reduced run of either counts as a failure rather than a pass.
   - **It checks the determinism rules by reading the code**: no clock, random source, environment or filesystem order reached for rather than passed in, no dependence on hash map iteration order, and sorting wherever output order could otherwise vary.
   - The release workflow ran green on the package's branch, on every platform, with no job having needed a rerun.
   - The repository rules are met, and the documentation and project map still match.
   - The journal entries exist and say something.
4. **If the review fails**, it writes its findings and hands back. How that hand-back works is set out below, because it is the join between two agents that never meet and it is where an autonomous loop most easily goes round in circles.
5. **After three rounds of the same disagreement**, the plan is what is wrong rather than the code, so the package goes to the back of `todo/` and comes back at the re-plan rung of the ladder, its worktree torn down and its history carried into the rewrite. If the disagreement is a choice rather than a defect, the reviewer decides it, records it in the package's findings with the alternatives it rejected, and the work continues under that decision.
6. **When the review passes**, the package moves to `merge-queue/`. It is not merged by the review agent and not by the implementation agent.

Several packages may be in flight when their dependencies have merged and the file sets their plans declare are disjoint. The orchestrator works the queues in priority order every turn (`conflicts/`, `merge-queue/`, `review/`, `todo/`) and ends the turn with `in-progress/` empty, reconciling anything left there as an unrecorded failure.

## How a review hands findings to the next implementer

The two agents never talk. One finishes, another starts later with none of its context, possibly on a different machine, possibly days apart. Everything that passes between them is a file, and getting that file right is what stops the loop going round in circles.

**Findings live in the package directory, one file per review pass**, beside that pass's evidence: `review-1/findings.md`, `review-2/findings.md`, and so on. They are never overwritten and never merged into one running document, so the full history of what was asked for and what happened is readable in order.

**Each finding is numbered and self-contained**, because the agent reading it has not seen the code before:

- **What is wrong**, in one sentence.
- **Where**, by file and line, in the worktree.
- **Why it fails**, naming the rule or the plan clause or the old-repository file it contradicts. A finding that cannot name what it violates is an opinion, and opinions are not findings.
- **What has to be true instead**, concretely enough to be checked. Not "improve the error handling".
- **How it was found**, so the implementer can reproduce it: the command, or the comparison against the TypeScript.
- **Severity**: blocking, or a note. Only blocking findings prevent acceptance, and a review that marks everything blocking has not done its job.

**The implementer replies in the same file rather than in a new one.** Each finding gets a resolution line written under it: fixed and how, or disputed and why. **A disputed finding is not ignored**, it is escalated in the record: the next review reads the dispute first and either accepts it, recording that in the findings, or restates the finding with better evidence.

**The next implementer's starting instruction is the plan plus the latest findings file**, in that order, plus every earlier findings file for context. That ordering matters: the plan says what to build, the findings say what was wrong with the last attempt, and reading them the other way round produces an agent that fixes symptoms and loses the goal.

**Three things the findings file must carry that a naive one would not:**

- **What was already accepted.** A review that only lists faults invites the next implementer to rewrite things that were fine. Each findings file opens with what passed, so the next pass knows what not to touch.
- **What was tried and rejected in earlier passes**, carried forward from the previous findings files, so pass three does not propose what pass two already disproved. This is the specific mechanism that stops the loop cycling.
- **The pass number and the rung of the escalation ladder**, so an implementer on pass three knows it is not doing the same thing again: pass three re-plans rather than re-implements.

**The review agent also writes its own journal entry**, which is a different thing and not a substitute: the findings file is instructions to one agent about one package, the journal is the record of what happened for a human reading later. Both, every time.

### Reading the reviews back

**A package's whole record stays with it forever, in one directory.** The package directory moves into `docs/queues/done/` as a unit, carrying its plan, every findings file and every evidence directory. Nothing is deleted on merge, and GitHub renders all of it in the browser.

**There is no index over packages and no cross-package summary of any kind**, other than the global `summary.md`. An index over forty packages is a file that has to be maintained on every merge, by an agent, forever, and it will be wrong before it is useful. The single global summary is the only place anything is aggregated.

**Instead, the last findings file of a package carries the wrap-up**, because it is written once at the end by an agent that has just read everything: how many passes it took, what each pass caught, what was disputed and how that resolved, and anything surprising. That costs one paragraph in a file that was being written anyway, and it means the story of a package is at the bottom of its own review rather than in a file somewhere else that has to be kept in step.

## The merge train

Merging happens in one place, by one agent, one train at a time. **Only one merge train may be active at any moment.**

1. The orchestrator starts a merge train when one or more packages are reviewed and waiting. It spawns a dedicated merge agent.
2. The merge agent creates a **new worktree for the merge**, from the current main branch.
3. It merges each ready package branch into that worktree, one at a time, in dependency order, recording each one in the journal as it goes.
4. It runs `bun run test:everything -- --force` in the merge worktree. Everything, not a subset, and not the change-detecting default.
5. **If anything fails**, it bisects: back the merged branches out and re-merge them one at a time until the failing one is identified, then hand that package back to its own worktree with the failure as a finding, recorded and routed by count. The train restarts without it. A package whose commits will not replay onto a main branch that moved goes to `conflicts/` instead, which is not a failure and counts toward nothing.
6. **If everything passes**, it merges the worktree into main, pushes, moves each package to `done/`, updates their rows in the parity ledger, then deletes every worktree and branch that went into the train.
7. Worktrees and branches are deleted the moment they are done with. A stale worktree is how this gets confusing, and a repository with fifteen abandoned worktrees is unworkable.

For this to hold from the first day, **`test:everything` has to work in the new repository from the very first commit**, even when it runs almost nothing. A test command that arrives late is a test command that was never run on the early packages.

## Phase 7: the parity audit

Phase 6 ends when every planned package has merged. **That is not the same as parity**, and the difference is exactly what this phase exists to find: things nobody wrote a package for, tests that were counted as ported but were not, behaviour that differs in a way no single package's review could see, and everything that was quietly dropped with a reason that does not survive being read again.

The audit is a fresh comparison of the two repositories, done by agents that did not build any of it, going back to `photosphere-old` rather than to the port's own records. **The port's records are what is being audited, so they cannot be the evidence.**

What it checks:

- **Every file in `photosphere-old`** is accounted for: ported, deliberately not ported with a reason that still holds, or superseded by something named. Anything not in one of those three states is a finding.
- **Every unit test case**, counted from the old repository rather than from the parity records, against what exists and passes in the new one.
- **Every smoke test**, by name, including the ones deduplicated between the desktop and mobile suites, confirming each survived the merge rather than being lost in it.
- **Every command line surface**: flags, help text, error wording, exit codes, output formats, compared against the old binaries.
- **Every on-disk and on-the-wire format**, by round trip against the old implementation, not by reading code.
- **Every document** the old repository had, and whether the new one says the equivalent thing.
- **The five-part comparison, sampled across packages**, to catch drift in the mirroring rule that per-package reviews let through one small improvement at a time.
- **The whole release workflow**, job by job, against the old one, confirming the almost one-to-one mapping and that nothing is still commented out.
- **Zero flakiness on the finished tree**: a full ladder at the hundred-run streak, the parallel check over every combination, and five sequential green release workflow runs.

**Everything it finds becomes a work package**, planned and queued like any other, and the port returns to phase 6 to build them. **Then phase 7 runs again, from scratch.** A second audit is not a re-read of the first one's list: it is another full comparison, because fixing one gap routinely reveals another.

**The loop ends when an audit finds nothing.** That is the only definition of done in this plan, and the criteria below are what "nothing" means.

Expect this to run several times. An audit that finds nothing on its first attempt has probably not been done properly, and an audit run by an agent that also built some of the work is not an audit.

## What "complete" means

Parity is not a judgement call. The port is complete when a phase 7 audit finds nothing, which means all of these are true at once, on a single revision of the main branch:

- Every package matches its TypeScript counterpart on all five parts of the comparison above, and where it does not, the divergence document says so and the human has accepted it.
- **Zero flaky tests.** `find-flakey-tests` completes a full ladder at the full hundred-run streak on the final tree, `check-parallel-tests` reports no interference across every combination including self-pairs, and the release workflow has run green five times in a row with no job needing a rerun.
- Every entry in the flakiness log is resolved, and every rule it produced is in `CLAUDE.md`.
- Every unit test from the old repository has a counterpart, and they all pass. The old repository has 164 unit test files across `packages/` and `apps/`; each one is accounted for as ported, superseded by a named Zig test, or written off with a reason.
- All eighty numbered CLI smoke tests pass, plus the encrypted, LAN share, hash cache, sync, write lock and keychain suites.
- The deduplicated UI smoke suite passes on Linux, Windows, macOS, Android and iOS. Where a test cannot run on a platform, the exclusion is written down with its reason and the human has accepted it.
- The CLI to application LAN share suite passes, replacing the current CLI to desktop one.
- A packaged artefact for each platform installs and launches, and the walking skeleton test passes against the packaged build rather than only against the development build.
- No TypeScript remains outside the frontend and the test harness, and every script, bundle, typecheck and TypeScript test runs under Bun.
- The documentation describes the new application, `docs/project-structure.md` matches the repository file for file, and the third party notices list every C library linked into a shipped binary with its licence and pinned version.

## How to run this autonomously

This section is the setup of the system that executes the port. The port itself runs remotely and unattended; what is here is what has to exist before it can, and the handful of points where a human reads or decides something.

**Nothing in this plan runs on a developer's workstation.** The port executes autonomously and remotely: in Claude's own cloud environment where that is available, and on a DigitalOcean droplet otherwise. Every runner is built from nothing by the setup document in the meta repository, and any machine that document cannot build is not a runner. A workstation is a place to read the journal and answer an escalation, not a dependency of the system.

### Runner classes

Building and testing divides by what the environment has to provide. **None of these is the port orchestrator**: they are where work gets built and tested, and all but the first are GitHub-hosted runners driven by the release workflow. The orchestrator is one machine that drives the loop and pushes branches; everything below happens because a branch was pushed.

- **Headless.** Linux, the pinned toolchain, the S3 emulator, network access to fetch dependencies, and credentials to push. No display, no GPU, no virtualisation. Covers Zig compilation, all three test passes, every unit test, all the CLI smoke suites, and the command line tool built for all four desktop targets from that one runner, because a pure Zig binary cross-compiles, which `what-changed` does today. This is most of the port by volume and all of packages 10 to 33, and it is the class the cloud environment and a plain droplet both satisfy.
- **Linux desktop.** Everything above plus GTK4, WebKitGTK 6.0 and `xvfb`. Runs the application smoke suite on Linux. A droplet satisfies this once the packages are installed; a headless container may not, and whether it does is a question the setup work has to answer rather than assume.
- **Android.** A machine that can run an emulator at usable speed, which means KVM. `ls -l /dev/kvm` on the candidate host is the check, run at the moment the host is provisioned and never assumed, because standard droplets are not guaranteed to expose it. If a droplet cannot, a provider that offers nested virtualisation or bare metal is the answer.
- **macOS.** A macOS host with Xcode, for the macOS desktop build and for everything iOS. This is the one class that cannot be provisioned from a Linux droplet at all, so it is either a hosted Mac runner or a Mac the port can reach.
- **Windows.** A Windows host with the WebView2 runtime, for the Windows desktop build and its smoke suite. Needed because the SDK builds on the target operating system.

### The release workflow already provides every runner class

`.github/workflows/release.yml` in the current repository is 1,744 lines and 22 jobs, and between them those jobs already run on every runner class this port needs: `ubuntu-latest` and `ubuntu-24.04` for the headless work, `windows-latest`, `macos-15-intel`, `macos-latest` and `macos-14`, and the Android emulator on `ubuntu-latest`, which the `android-smoke-tests` job enables KVM for with a udev rule before booting an AVD. **That settles the question the Android lane was open on: GitHub's Linux runners expose KVM, so the Android suite does not need a droplet or bare metal.** iOS unit and smoke tests already run on `macos-14`.

Two consequences. The port has hosted runners for all five classes without buying or hosting anything, and the pinned Xcode 14.2 environment is a constraint on local development rather than on CI, which already builds and tests iOS on a newer macOS image. That makes a negative result from prototype P2 less severe than it first looks: it costs local iOS development, not the iOS platform.

### The architecture: cloud sessions, with a droplet as the fallback

**Decided: architecture B, Claude Code cloud sessions.** Architecture A, a long-lived droplet, is kept as the fallback and is not discarded, because B rests on a research preview and on limits that have not been measured against this workload.

Both do the same work and use the same queues, plans, evidence and records. Nothing in the process design depends on either, which is what makes the fallback cheap.

**Switch to A if any of these turns out to be true**, and record the switch as a process decision:

- Cloud sessions are not available on the account, or stop being.
- The 30 GB disk or 16 GB of memory will not hold a build of this size, and neither will trimming what is on disk.
- Sessions cannot run long enough, or concurrently enough, to be worth the difference.
- The merge-by-pull-request path cannot be made to work.
- The network allowlist cannot reach something the toolchain needs.

**Architecture A, the fallback:**

- A DigitalOcean droplet runs the orchestrator continuously.
- It serves the headless work itself and the Linux application suite once its packages are installed.
- Other platforms are reached the same way as under B: push a branch, let the release workflow test it.
- **What it needs**: one droplet provisioned from `docs/orchestrator-setup.md`, with credentials to push and something that keeps the orchestrator running.
- **What it buys over B**: no research preview, no resource ceiling but the machine's, no push restriction, so the merge train pushes main directly and the process is exactly as this plan describes it elsewhere.
- **What it costs**: a machine to pay for and maintain.

**Architecture B: Claude Code cloud sessions.**

The orchestrator and every agent run as Claude Code cloud sessions rather than on a machine anybody owns. What follows is from https://code.claude.com/docs/en/cloud-environments and decides most of the design, so it is recorded here rather than assumed.

**What the documentation says, and what each fact costs or buys:**

- **Each session gets a fresh VM**: Ubuntu 24.04 on x86_64, the repository already cloned, common toolchains pre-installed. Sessions are independent, so several run at once. That is the parallelism the scheduled-job version could not give.
- **4 vCPUs, 16 GB RAM, 30 GB disk**, and the VM may stop tasks that need significantly more memory. This is a real constraint for this port: `photosphere-old`, `photosphere-zig`, several worktrees, a Zig cache and the C library builds all share 30 GB, and Zig builds are memory-hungry. Measure it early; the documented answer for workloads beyond it is Remote Control on your own hardware or a self-hosted environment.
- **A setup script runs once, then the filesystem is snapshotted and reused.** Later sessions start with the toolchain already on disk and skip the script. This removes the per-session setup tax that made the scheduled-job version slow. The cache keeps files, not running processes, so anything long-lived (the S3 emulator) starts per session. It rebuilds when the script or the allowed hosts change, and after roughly seven days.
- **Network access is per environment**: none, a trusted allowlist covering package registries and GitHub, or a list you specify. Fetching Zig, the SDK and the C dependencies has to be checked against that allowlist rather than assumed.
- **GitHub goes through a proxy**, and it carries a restriction this plan has to design around: **`git push` works only against the session's current working branch.** Cloning, fetching and pull request operations work normally. Two consequences: an agent can push its own package branch, which is what it needs; and **the merge train cannot push main directly**, so merges land through pull requests instead. So does anything the orchestrator writes to the meta repository, unless the orchestrator's session treats the meta repository as its working repository.
- **API access is scoped to repositories attached to the session**, so all three repositories are attached, and a fetch from an unattached one gets a 403.
- **`gh` is not pre-installed** and goes in the setup script. With no token set, `GH_TOKEN` reads as a placeholder and the proxy substitutes real credentials on outbound requests; a script that reads the variable directly gets the placeholder rather than a usable token. Anything the port writes that expects a real token has to account for that.
- **There is no secrets store.** Environment variables are readable by anyone using the environment. Credentials therefore rely on the proxy rather than on variables wherever possible.
- **Scheduling exists as routines**, which start sessions on a schedule in a chosen environment. That is the backstop wake-up, without a CI job hosting the loop.
- **It is a research preview**, on Pro, Max, Team and some Enterprise seats. Availability is the first thing to confirm.

**What this means for the design**: parallel long-lived sessions with a cached environment, merges landing by pull request rather than direct push, all three repositories attached, and disk and memory measured before it is trusted with the whole port.

### What architecture B looks like in practice

**The orchestrator is a long-running session.** It holds the loop: reads the queues, decides what is next, spawns agents, drives merge trains, keeps `summary.md` true. It is not restarted every few minutes and pays no setup cost between decisions.

**Each agent is its own session, and they run concurrently.** An implementer for package 13, a reviewer for package 11 and a merge train can all be live at the same moment, each in its own environment with its own worktree. Concurrency is bounded by what the plan already says: dependencies satisfied, declared file sets disjoint, one merge train at a time.

**GitHub Actions keeps one job and loses the other.** It is no longer the scheduler and no turn runs inside it. It still runs `release.yml` on branch pushes, because that is where macOS, Windows and Android testing lives and none of that needs owning hardware. It matters more here than under architecture A, because a cloud session has no Android emulator, no Mac and no Windows: everything platform-specific is the workflow's job by necessity rather than by preference.

**Merging happens through pull requests**, because the proxy allows a session to push only its own working branch. The merge train opens a pull request from its merge worktree, the release workflow runs against it, and it is merged when green. That is a change from the direct push the merge train section describes, and it is the one place architecture B alters the process rather than just where it runs.

**Where the long work goes, and why the wait is no longer serial:**

- **Fast local checks run inside the agent's session**: compile, the three Zig passes, unit tests, the CLI smoke suites. These block, in the foreground, as the rules require.
- **The slow multi-platform suites run in `release.yml`**, started by the branch push the agent makes.
- **The agent waits for that run inside its own session** rather than ending and being picked up later. A session that can run for hours can afford to wait forty-five minutes for Android, and while it waits every other session keeps working. This is the thing the Actions version could not do, and it is why that version was slow: there, waiting meant ending the turn and paying the whole hand-off again.
- **If a session cannot outlast a workflow run**, the fallback is the recorded-wait design: the agent writes which run it is waiting on and ends, and the orchestrator picks the result up when it lands. That path exists either way, because it is also what happens when a session dies mid-wait.

**Scheduling becomes triggering.** There is no fixed cadence to tune. The orchestrator acts when something is ready: a review finishes, so the merge queue moves; a workflow goes green, so a package advances. A periodic wake-up remains only as a backstop, to catch anything that finished while nothing was listening.

**What replaces the invocation limit as the backstop.** In the Actions version, a stuck agent died when its job timed out. With long-lived sessions that is gone, so it falls back to the orchestrator's own check at the top of each pass: an agent record that has stopped moving gets its session killed and restarted from its last checkpoint. A stuck orchestrator is still visible from the heartbeat in `summary.md`, and killing and restarting it is safe.

**Watching it.** The heartbeat line in `summary.md`, the queues, and the agent records, exactly as everywhere else. There is no run history to read instead, which is a small loss against the Actions version.

**What this costs.** Sessions that sit waiting on a workflow are consuming a slot and possibly budget while doing nothing, so the concurrency ceiling and the budget ceiling both matter more here than in the Actions version, where waiting was free because the job had ended.

**Falling back to A** costs one process change, in the opposite direction to the one B introduced: the merge train pushes main directly instead of opening a pull request. Everything else, the queues, the plans, the evidence, the records and the release workflow, is unchanged, which is what makes the fallback a day's work rather than a redesign.

The consequence, whichever is chosen: **the system converges to everything green except the classes it has no runner for.** Since the release workflow already covers all five, that should be nothing, and if a class does go missing the packages needing it queue up while everything else keeps moving.

### Setting it up

1. **Do the cold start**, exactly as set out in the section of that name. An agent creates both repositories and everything in them; the only human action in the whole port up to this point is supplying the Claude credentials the scheduled turns run under.
2. **Step 1 of the port runs, and then waits for a human.** An agent writes `photosphere-zig`'s `CLAUDE.md` and the whole documentation set and stops. The human reads them and accepts or changes them, `docs/project-structure.md` first and hardest, because every plan is written against it. Nothing else starts until that acceptance is recorded. The unattended system inherits whatever is in these files, which is why this is the one review that cannot be delegated.
3. **Phases 2 and 3 answer the ten questions and absorb the answers.** The prototypes are built by the orchestrator from the meta repository, except P2, which needs a Mac carrying Xcode 14.2. Every decision that comes out of a negative result is recorded, and the ones that change the port's route are put in front of you.
4. **Provision the port orchestrator**: the droplet or the cloud session it runs on, with mise, the Zig and Bun versions the prototypes pinned (plus Node if P1 found the SDK CLI needs it), the GTK4 and WebKitGTK 6.0 development packages, `xvfb`, the C library build dependencies, GNU Stow for the bootstrap, and the S3 emulator. Confirm the pinned toolchain installs from a clean machine and write down the exact commands, because that list is also what a new developer needs.
5. **Write the plans for packages 10 to 20 before starting the loop**, and write them the same way the port will be run: a subagent per plan with `/plan:create`, then a separate subagent with `/plan:check`, then a fix pass with `/plan:fix`, repeating until the check comes back clean. Different agents for writing and checking, because an agent checking its own plan finds nothing. The loop consumes plans faster than it produces them, and a queue of clean plans is what keeps it fed.
6. **Set up the orchestrator.** Two ways, and the second is the fallback for the first:
   - A slash command in the meta repository (`/port:next`) that performs exactly one cycle of the loop above and exits, driven on a schedule so that each tick picks up wherever the last one stopped. Scheduling can be a cron entry created from inside a session or a plain system cron calling headless mode.
   - A shell script on the droplet in a loop, calling Claude Code in headless mode with the same command, one cycle per invocation, sleeping between cycles.
   Either way the unit of work is one cycle, not one package and never the whole port, so a crashed or killed process loses one cycle.
7. **Keep the state outside the agent, in the queues.** The queue directories in the meta repository are the state, every move is committed, and the history of those commits is the audit log. The orchestrator reads the board at the start of a turn and leaves it consistent at the end. An agent's memory of what it was doing does not survive a restart; a directory does.
8. **Nothing stops for you, so read `summary.md` instead.** There is no queue waiting on a human and no notification to answer. A package that keeps failing climbs the escalation ladder by itself and appears in the struggling section of the summary with its rung and its attempt count. Decisions taken autonomously appear there too, so you can reverse one early rather than being asked for it up front.
9. **Set the limits before starting, not after.** A token or spend ceiling per cycle and per day, a maximum number of concurrent packages (two or three, because merges serialise anyway), and a stop file that the orchestrator checks at the top of every cycle so you can halt the whole thing without killing a process mid-commit.
10. **Review the merge stream daily, not the code.** The review agent reads the code; you read what merged, which tests moved from red to green, and every escalation. If the same finding keeps appearing across packages, that is a `CLAUDE.md` amendment, not a per-package fix.

### What the autonomous system must never be allowed to do

- Commit with the verification hook disabled, in any form, for any reason.
- Modify the hook or the scripts it calls.
- Force push, rewrite history, or delete a branch that has not merged.
- Write to `photosphere-old`. It is opened, read and diffed against, and nothing else.
- Run more than one merge train at a time, or merge a package branch to main outside a train.
- Finish a piece of work without writing its journal entry.
- Start, stop or repair the Android emulator pool beyond the repair commands the rules allow, or race the pool monitor by repairing an emulator it is already fixing.
- Mark a package done on the strength of a report rather than a run. The review agent runs the tests itself, and the orchestrator runs the full suite after the merge.
- Skip, disable or weaken a test to make a package pass. A failing test that cannot be fixed climbs the escalation ladder.
- Retry a red job and treat the green as the answer. A job that passes on retry is flaky, which stops everything until it is fixed and proven by five sequential green workflow runs.
- Accept a package without the flake hunter and the parallel check having been run by the reviewer, in full, over every suite.

## Risks, in the order they can bite

Each is a risk to a route, not to the port. Each entry names the alternative route.

1. **iOS under Xcode 14.2** (prototype P2). The generated Xcode project is the newest, least documented part of the SDK and the pinned Apple toolchain is three years older than it. This is the likeliest thing to force a decision, and the decision is about which Apple machine and which toolchain, not about whether the port happens.
2. **The SDK's mobile support being experimental in the vendor's own words**, with a 404 for its documentation and nothing in the probe ever built for a phone. P2 and P3 are the only evidence that will exist.
3. **The C libraries on mobile targets** (prototype P4). If the AWS C runtime will not build for Android or iOS there is no permitted workaround inside the rules, so the answer is a different library, a different arrangement, or S3 arriving on mobile later. Not a hand-written substitute.
4. **An SDK moving from 0.0.0 to 0.8.4 in five weeks** under a port that will take months. Pin exactly, upgrade deliberately, and expect breaking changes.
5. **WebKitGTK 6.0 not being on users' machines.** This is a shipping problem rather than a development one, and it needs an answer before the first release rather than after.
6. **The comparison rule decaying.** The line-by-line correspondence is what makes the port reviewable, and it degrades one small improvement at a time. The review agent checking it on every package is the only thing that holds it.

## Notes

- **Facts about the old repository, carried forward so they are not rediscovered**: `IStorage` has seventeen methods; the task handlers are nineteen files producing twenty-two names across two registration sites (`packages/node-api/src/lib/task-handlers.ts` registers nineteen, and `packages/mobile-worker/mobile-worker-entry.ts` registers those plus `list-s3-dirs`, `read-databases-config` and `write-databases-config`, and is the only place in the repository that registers those three); `apps/desktop/smoke-tests/` holds 34 tests and `apps/smoke-tests/tests/` holds 43, sharing 27 names for a union of 50; `apps/cli/smoke-tests/` holds 80 numbered tests; there are 164 unit test files under `packages/` and `apps/`; `std.crypto` has no CBC mode and no RSA; and both the desktop and mobile suites already drive the application through the same control bridge and the same shared test driver in `packages/user-interface`, which is what makes one deduplicated UI suite possible.
- **The two registration sites become one.** One application, one handler set, and a test that asserts it, so a handler cannot be lost silently the way the mobile-only three could be today.
- **Known divergences from the TypeScript**, to be recorded in the port's divergence document as they land: `async` becomes blocking plus an explicit thread pool, with cooperative cancellation through an explicit token because a blocking thread cannot be interrupted from outside; interfaces become vtable structs; every allocating function threads an allocator; the queue backend stops being a process singleton and is passed explicitly; the path sandbox moves out of Java and Swift into Zig; the asset server validates its route parameters where the Express one does not; BSON, RSA, AES-CBC and PEM come from C libraries; every Electron IPC channel and every Capacitor plugin call becomes a bridge command; and Zig 0.16 routes blocking calls through a `std.Io` instance.
- **The macOS keychain exposure comes across unchanged.** The current code passes the secret as an argument to `security add-generic-password -w <json>`, and process arguments are readable by other processes. Port it as it is so existing installations can still read their secrets back, record it, and raise it with the human when that package lands. Do not fix it in passing.
- **`what-changed` is the written-down answer to "how is Zig done here"**, and its commit history is where the reasoning lives rather than in the code: https://github.com/ashleydavis/what-changed. The two commits worth reading before writing anything are `ef5eecb`, which removed a global `std.Io` and passed it explicitly, and `0a33bc7`, which deleted 43 comments that justified a decision by naming the TypeScript it was ported from. Both are rules in this plan and both were learned the expensive way there.
- **The two probes are the best reference material available.** https://github.com/ashleydavis/electron-alternative-vercel-native is the one this plan builds on. https://github.com/ashleydavis/electron-alternative-zig-with-webview solves the same problem against the raw `webview` C binding: read it for its message queue. Their shared conclusion: the hard parts (the threading rule, range requests, the WebSocket lifecycle) belong to the WebView model rather than to the wrapper, so they hold whatever happens to the SDK.
- **There is an old worktree of unfinished Zig in the old repository, and this port does not use it.** `.claude/worktrees/zig-core-port` holds roughly 27,000 lines across sixteen module directories, uncommitted, never verified to build or pass, and written for a layout this plan does not use. **Do not read it, do not copy from it, do not merge it, and do not cite it.** Everything this port needs comes from `photosphere-old`, which is committed, tested and shipping. Anything in that worktree worth having would have to be re-derived from the TypeScript anyway, and taking a shortcut through it is how a stale assumption gets into the port without anyone noticing where it came from.
- **This plan is transient.** Nothing that outlives the port may reference it. Anything in here worth keeping (the writing rules, the divergence list, the toolchain versions, the packaging steps) gets copied into the new repository's own permanent documents, in full, at the point it is needed.
