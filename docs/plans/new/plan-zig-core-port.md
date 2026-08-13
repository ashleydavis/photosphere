# Port Photosphere to Zig and Vercel Native, in a new repository

## Overview

Photosphere today is sixteen TypeScript packages under `packages/` plus ten apps under `apps/`, wrapped for the desktop by Electron and for the phone by Capacitor, with background work running inside an embedded JavaScript engine (QuickJS on Android, JavaScriptCore on iOS) driven by a host bridge.

This plan replaces all of that with a **new repository** containing a Zig core, a Zig command line tool, and a single **Vercel Native** application shell that covers Windows, Linux, macOS, Android and iOS. Electron and Capacitor both go. The React user interface is carried across unchanged and is not ported: Vercel Native embeds a directory of built frontend assets and serves them to the system WebView, so the UI keeps being TypeScript and React and becomes the only TypeScript that ships.

**Bun stays.** Wherever TypeScript or a script survives into the new repository, Bun is what runs it: the workspace and its dependencies, every `package.json` script, the bundling of the React frontend, the TypeScript unit tests, and the host-side pieces of the smoke test harness. The one thing that may not be Bun's to run is the Vercel Native CLI itself, which ships on npm and states Node 22.15+ as its requirement; whether it runs under Bun is a question for prototype P1 and is not assumed here.

The work is cut into individually testable packages of work, each with a written specification, unit tests and (where the package can be reached from outside) smoke tests. The intended way to execute it is autonomous: an orchestrator picks the next ready package, an implementation subagent builds it in its own transient worktree and commits, a review subagent checks it against the specification and runs the tests, and the two hand back and forth until the review passes. The final section of this document tells the human how to set that up and what it cannot do without them.

**Step 1 stops.** The first thing that happens in the new repository is a `CLAUDE.md`, and then nothing else until the human has read and accepted it.

### A concern worth stating before the plan starts

The previous version of this plan existed because two attempts at a big-bang Zig port failed, and its central finding was that a parallel tree produces nothing testable until roughly two thirds of the way through, which is why it ported packages in place behind the existing interfaces so that the existing smoke suites were the evidence after every increment.

A new repository throws that safety net away by construction. There is no existing application calling the new code, so the same failure is available again. The plan below answers it in a different way rather than pretending the risk is gone: the walking skeleton (a launchable window, a working control bridge and one passing smoke test) is built before any core library, the command line tool comes online early because its eighty smoke tests are headless and can run anywhere, and every work package after the skeleton has to make at least one more real test pass in a real binary. If a work package cannot state which test goes from red to green, it is the wrong package.

### This port gets done

That is the premise, not an aspiration, and it settles what everything below means. Nothing in this document is a question about whether the port happens. Every prototype, finding, risk and decision in here is about **how** it gets built: which route, which dependency, which platform arrives first, which requirement gets raised. A negative result is a change of route and never a reason to stop.

Two things follow, and they are the reason to state this up front rather than leave it implied. An agent that hits a wall reports it and waits for the route to change; it does not decide the work is off, and it does not invent a workaround the rules forbid to keep going. And a decision that has to be made is made by the human and then executed, rather than being left open as a standing doubt about the project.

## Prototypes: the inputs this plan expects

**These are not this plan's work.** They are built separately, each in its own repository, and what reaches the port is a link and a finding. Two exist already. The rest are briefs, written here so that what comes back answers something the port can act on.

Ten questions can each change what this plan is, and every one is cheaper to answer in a throwaway prototype than to discover in the middle of the port. Phase 1 is the port reading the findings and adjusting to them, and that is the only place the port depends on this section.

What makes a prototype usable here: one question, thrown away afterwards, and a written finding saying what was run, on what, and what happened. A prototype that ends in an opinion cannot be acted on.

A negative result moves work: a different route, a different dependency, a platform that ships later than the others, or a requirement that gets raised. That is the value of running them first, while a decision is still cheap to act on. What a negative result must never do is get worked around quietly.

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

This is the model that packages 23, 33 and 36 are built on, and it is the one piece of the architecture that has no equivalent anywhere in the current repository, because there the concurrency came from an event loop that no longer exists.

**P9. Compatibility with data and installations already in the field.** Users have databases on disk written by the TypeScript, and after this ships they will have a Zig phone talking to a TypeScript desktop over LAN sharing, because nobody upgrades everything on the same day.

Build it: a Zig program that opens a real database written by the current application, reads its records through libbson, reads its serialised structures, and computes the same merkle root hash the TypeScript computes, asserted against the checked-in fixtures. Then, smaller: a Zig LAN share sender against the current TypeScript receiver, and the reverse.

It passes when the root hashes match on every fixture database in the repository, when every record compares equal field for field, and when a database written by the Zig side is opened by the TypeScript side without complaint. Where libbson and the `bson` npm package disagree, name the type.

This decides whether the work is a port or a port plus a migration, and that has to be known before the port starts rather than when the first user opens their library.

**P10. The autonomous loop itself, on a throwaway package.** The port is meant to run without a human in the loop for long stretches. That machinery has never been run.

Build it: one real cycle of the loop in the real runner environment, on a small package of work that does not matter. Orchestrator picks it, implementation agent builds it in a transient worktree and commits with the hook enabled, review agent runs the tests itself and rejects it at least once on purpose, they iterate, the orchestrator merges, runs the full suite, removes the worktree and updates the state file.

It passes when a package goes from ready to merged with no human intervention, when a deliberately broken implementation is caught by the review agent rather than merged, and when killing the orchestrator mid-cycle and restarting it loses one cycle rather than confusing the state. Record what the cycle cost, because that number times forty is the port's budget.

This is the one prototype in the list with nothing to do with Zig or the SDK, so it does not need a repository of its own: running it as the orchestrator's first cycle against a throwaway package in the new repository is the same experiment.

Run it in the environment the port will use, so it also answers the runner questions: whether remote Claude sessions are available and can reach the network and the repository, what `ls -l /dev/kvm` says on the droplet, and whether the application smoke suite runs under `xvfb` there.

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

### Several of this port's load-bearing features are already prototyped there

The probe is not only where the facts above come from. It is working code for the parts of this application that are hardest to get right against a WebView, it was built by the same author against the same eventual purpose, and it has been built and run on Linux. **Read it before writing any of these, and start from it rather than from the SDK documentation**, which the probe itself found to be wrong or silent on two of its three central APIs. The mapping onto the work packages below:

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

Three things in the probe are prototype quality and must not be copied as they are. It builds JSON with `bufPrint` rather than a serialiser, which is fine for integers and wrong the moment a filename or a user string goes into a payload, so this port uses `std.json` throughout. Its bridge policy allows `zero://inline` so the automation harness can dispatch, which is a security decision to make deliberately rather than inherit. And its progress path is a single monotonic counter, which the probe's own README says stops working once more than one job runs at a time: Photosphere runs many concurrent tasks, so package 23 needs task ids in every event and a real queue rather than a high-water mark. The sibling probe at https://github.com/ashleydavis/electron-alternative-zig-with-webview already has that queue as a fixed-capacity ring buffer and is worth reading for it.

The costs, each of which the plan has to deal with:

- **Zig 0.16.0 exactly**, pinned by the SDK. Zig 0.16 routes sleeping and other blocking through a `std.Io` instance rather than free functions, which changes how every blocking call in the port is written.
- **A JavaScript runtime is a build-time dependency** for a Zig program, because the SDK ships as an npm CLI and states Node 22.15+ as its requirement. Bun installs it and Bun runs the scripts around it either way; the open question is whether the CLI's own code runs under Bun or needs Node underneath it. Step 2 answers it by running `native build`, `native check`, `native package` and both mobile targets under Bun. If any of them needs Node, Node is pinned in `mise.toml` for that one purpose and nothing else, and the port says so where a reader will find it.
- **Build on the target operating system.** Zig cross-compiles readily on its own, but this links against platform SDKs and system libraries, so Windows, macOS and Linux each need their own runner. The previous plan's four-target cross-build story is gone for the application shell. It survives for the command line tool, which links nothing platform-specific: `what-changed` cross-compiles all four desktop targets from a single Linux runner today, and the Zig CLI here should be able to do the same. That difference is worth a lot to the autonomous lanes below.
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
- `lib/psi-core/**` gets no mutable globals at all. Constants are fine. A `const` table is fine. A `var` at module scope is not, whatever it is protecting itself with.
- State that has to exist lives in a struct the caller owns and passes in, so two of them can exist at once and a test can make one.
- Effects are parameters: the allocator, the `std.Io`, the clock, the UUID source, the network and the process spawner all arrive explicitly, which is also what makes the deterministic test implementations the smoke tests rely on possible. A struct may hold the effect it was constructed with, because a temporary directory only makes sense against the filesystem that made it, but nothing reaches for an effect it was not given.
- The test for whether this rule is being followed: reading a function tells you which implementation a call uses, and no test can change what another test sees. If either fails, there is a hidden global whatever it is called.
- Globals are tolerated only at the edges: `src/main.zig` and the platform host it talks to, the CLI entry point, and the process-level runtime the SDK owns. Even there, the global is a container that is constructed once at startup and passed down, never reached back up into.
- Keep a written list of every container-level variable left in the repository, and drive it down. The last port ran that list to four and named them.
- The old `setQueueBackend`/`getQueueBackend` process singleton is the exact pattern this rule exists to stop. It does not come across.

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

The port replaces application code. It does not replace the machinery around it, and none of that machinery is allowed to be lost, reinvented or quietly left behind because a work package did not need it that day. Years of this repository's value is in these scripts rather than in the packages, they are all shell or TypeScript so nothing about Zig makes them obsolete, and losing one is not noticed until the day it was the thing that would have caught a problem.

Every item below is carried over, kept working, and covered by the step 1 documentation. Where a script names Electron, Capacitor or a package that no longer exists, it is edited to name the new equivalent; it is not dropped.

- **`scripts/test-everything-parallel.sh` and the whole `test:everything` arrangement.** This is how a change is tested in this repository and it is what the git hook runs. It comes across with its parallel lanes, its per-script decisions, its `--plan` and `--force`, and its serial groups.
- **`what-changed` and `what-changed.yaml`.** The new repository uses the same tool the same way, targets and all, so a docs-only change still runs nothing and a Zig change runs what it affects. It is already a Zig program by the same author, so this is one dependency that gets simpler rather than harder.
- **The git hooks: `.githooks/pre-commit` and `scripts/install-hooks.sh`.** Carried over and then frozen again under the same rule: never edited, never bypassed, and never given an escape hatch.
- **`scripts/find-flakey-tests.sh`**, with its streak target, its resume, its ladder mode and its finish-time estimates. A port produces new tests at a rate nothing else in this repository ever has, so the flake hunter matters more here than it does today, not less.
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
- **Phase 1: intake of the prototype findings.** Absorb what the prototypes settled and change the plan where they changed it.
- **Phase 2: the walking skeleton.** A launchable application, the test harness, the operational scripts and the release workflow, all working before any library is ported.
- **Phase 3: the shakedown.** One package, end to end, through every part of the machinery, one at a time, iterating on the system until it needs no more changes. **Ends at a human checkpoint.**
- **Phase 4: the port.** Every remaining package, several in parallel.

Nothing about phase 4 is attempted until phase 3 has run clean, and nothing in phase 3 is attempted until phase 0 has been read and accepted.

## The cold start: how this gets going at all

Before phase 0 there is nothing: no meta repository, no runner, no orchestrator, and this plan sitting in the old repository where no part of the port can see it. This section is how that becomes a running system, and it is the one part that a human performs rather than reads.

**The human creates nothing.** The bootstrap is done by an agent in a session, from a machine that already has git and GitHub credentials, and the only thing a human supplies is the one thing an agent cannot: the credentials the automation will run under.

What the bootstrap session does, in one sitting:

1. Creates `psi-zig-port`, private, and pushes it with this plan in it as `docs/plan.md`.
2. Writes the scheduled workflow whose only instruction is to take a turn, and commits it.
3. Creates `photosphere-new`, private, with an empty main branch, and clones `photosphere-old` and `claude-config` into the meta repository.
4. Does the rest of phase 0: bootstraps `claude-config`, writes the queues, the journal, the decisions and interventions directories, `summary.md`, the stub repository, the rules and the documentation set.
5. Stops at the phase 0 checkpoint for the human to read.

**The one thing only a human can do is supply the credentials**, because they cannot be minted by an agent: the Claude credentials the scheduled turns will run under, added as a repository secret. Without them the workflow exists but cannot run. Everything else, including the repositories themselves, is created by the bootstrap session.

Under the long-lived architecture there is additionally a machine, and that is a genuine cost of that option: a droplet has to be brought up before anything can run, and the setup document describing how gets written afterwards from what was done rather than being followed. That is the wrong way round, and it is another reason to prefer scheduled turns.

Under the long-lived architecture there is a machine, and that is a genuine cost of that option: a droplet has to be brought up and prepared before anything can run, and the setup document describing how gets written afterwards from what was done rather than being followed. That is the wrong way round, and it is another reason to prefer scheduled turns.

**What has to exist beforehand either way**: the source repositories reachable on GitHub (`photosphere`, `claude-config`, and the prototype repositories), a machine with git and GitHub credentials for the bootstrap session to run from, and the Claude credentials above.

**The order the bootstrap session works in**, because each step depends on the one before:

1. Start the journal with an entry describing the cold start itself, before doing anything else, so that everything after it is recorded as it happens. The first journal entry being the creation of the journal is the right kind of circular.
2. **The plan is already in place** as `docs/plan.md`, put there by hand when the repository was created. From that moment it is the plan, and the copy in the old repository is a historical artefact whose first line says so. Every later amendment happens in the meta repository, with a journal entry saying what changed and why, so the plan carries the same history as the work.
3. Clone `claude-config` into the meta repository, run its `bootstrap.sh`, and replace the stowed `settings.json` with permissions set to bypass. The plan skills are now available, which the rest of the port assumes.
4. Clone `photosphere-old` at the `mobile` branch, read-only.
5. Create `photosphere-new`, private, with an empty main branch.
6. Write the runner setup document, so that anything the environment needed is captured while it is still known rather than reconstructed later. On a per-job runner this is short: what to install before a turn can work.
7. Then the rest of phase 0: the queue directories, decisions, interventions, `summary.md`, the stub repository, the rules and the documentation set.

**How the orchestrator starts the first time.** Once phase 0 is accepted, the first orchestrator turn is started the same way every later one is: on the chosen architecture, either a scheduled invocation or a loop on the runner, pointed at the meta repository with the instruction to take one turn. It reads the queues, finds phase 1 outstanding, and works. There is no separate startup path and no first-run special case, because a special case is a path that is exercised once and therefore never tested.

**How a second runner joins.** Clone the meta repository, follow the setup document, bootstrap, and start taking turns. Nothing else is needed, because all state is in the repository rather than on a machine. If that is not true when it is tried, the setup document is wrong and fixing it is the first job.

## Phase 0: setup and structure

Everything that has to exist before any porting starts, and nothing else. No Zig, no application code, no ported package. This phase is words, structure and scaffolding, and it ends by stopping.

**0a. The meta repository.** Create `psi-zig-port`, private. Inside it: clone `claude-config`, clone `photosphere-old` at the `mobile` branch as a read-only reference, and create `photosphere-new`, private, with an empty main branch. Write the meta repository's own `CLAUDE.md`, covering the recording rules, the commit and push cadence, the concurrency rules below, and the rule that `photosphere-old` is never written to. Create the queue directories, the empty journal, the decisions directory with `docs/decisions.md` as its index, the interventions directory, and `summary.md` with every package, every release workflow job and every prototype listed and unticked. Write the runner setup document that brings a fresh machine up from nothing. No scripts: this repository holds words, structure and records, and nothing that has to be maintained as software.

**0b. The stub new repository.** `photosphere-new` gets its skeleton and nothing more: `mise.toml`, `package.json`, `build.zig`, `app.zon`, the directory layout, a `test:everything` that runs and reports what it found while there is almost nothing to run, `what-changed` and its configuration, the git hooks installed, and the release workflow copied over with everything not yet implemented commented out. It compiles, its tests pass, and it does nothing else. The point is that the machinery around the first package exists before the first package does.

**0c. The rules and the documentation set.** `photosphere-new`'s `CLAUDE.md` and its entire documentation set, as detailed below. This is the part that everything else inherits.

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
- `docs/porting.md`: the index from old file to new file, the work package contract, and the implementation and review loop.
- `docs/building-and-packaging.md`: per platform requirements, the system libraries, packaging, and the release layout.
- `docs/mobile.md`: the Android and iOS toolchains, what the SDK generates, and the pinned Apple environment.
- `docs/git-hooks.md`: what the hook runs and why it is never bypassed.
- `THIRD-PARTY-NOTICES.md`: started now with the SDK and the C libraries, extended as each lands.

Documents written before the code they describe will contain claims that turn out to be wrong. That is acceptable and expected: they are a specification at this point, and each work package that contradicts one has to correct it as part of its own review. What is not acceptable is a document that describes something as working when nobody has run it, so every claim about behaviour in the step 1 set is written as intent rather than as fact, and the prototype findings taken in during phase 1 are what convert them.

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
- **The reference implementation.** `what-changed` is how Zig is written here: read it and its commit history before writing any, and follow its conventions on structure, testing against real files rather than mocks, smoke tests driving the built binary, named constants carrying their reason, and error sets split where the caller treats them differently.
- **The autonomy contract**: what a work package is, what an implementation agent may and may not do, what a review agent checks, and the escalation rule when they cannot agree.
- **Documentation and comment rules**, carried over unchanged, including the ban on em dashes, on `---` separators, on hard-wrapped prose, on the words this repository bans, and on machine-specific absolute paths in anything checked in.

## Phase 1: intake of the prototype findings

The prototypes are not this plan's work. They are built separately, and what arrives here is a set of repositories and findings. This phase is what the port does with them: read them, record what they settled, and act on what they changed. It is short by design, and it is the last point at which the port is cheap to redirect.

**2. Read the prototype repositories and write the findings into the new repository.** For each one: what it proved, what it refused to do, and every version, system package and command that came out of it. The destinations are the documents from step 1, not a document of its own, because a finding filed somewhere nobody reads is the same as no finding.

- Toolchain and versions, into `mise.toml` and `docs/development.md`: the Zig version, the exact SDK version, the Bun version, whether Node is needed and for which commands, and the system packages each platform requires.
- The build arrangement, into `build.zig` and `docs/building-and-packaging.md`: whether the build is ejected, how the frontend is bundled, how the development loop works, and what the packaging commands are per platform.
- The platform picture, into `docs/mobile.md` and `docs/building-and-packaging.md`: which platforms build, which need something the port does not yet have, and what each one needs from the user's machine at runtime.
- The C dependencies, into `build.zig.zon` and `THIRD-PARTY-NOTICES.md`: every library pinned by exact tag and content hash, never a branch or a floating reference, so a swapped upstream artefact fails a hash check rather than being fetched silently, with its licence and the advisory feed to check before each release.
- The architecture, into `docs/architecture.md` and `docs/how-it-works.md`: the threading rule, the three channels, the concurrency and cancellation model, and the media path.
- Anything the prototypes could not do, into the plan itself: a package that cannot be built the way this plan assumes gets its entry rewritten here before it is specified, not when an agent reaches it.

**3. Act on whatever the findings changed.** A prototype that came back negative moves work rather than removing it: a platform ships later, a dependency is swapped, a capability becomes a package of its own, or a requirement is raised. Make those changes to the work package list in this document, with the reason, and put the changed list in front of the human before phase 2 starts. Do not carry an assumption forward on the grounds that the plan already said it.

**4. Confirm the two writing rules survived contact with real code.** The prototypes are the first real Zig written against this SDK. If the rules made something impossible or absurd there, amend them now, in `CLAUDE.md` and `docs/zig-conventions.md`, and say what forced the change. Rules amended after forty packages are written are not rules.

**5. Pin the baseline.** The versions, the system requirements and the decisions from steps 2 to 4 are the starting state of the port. Everything after this treats them as fixed, and a change to any of them is its own work package with the full suite behind it.

## Phase 2: the walking skeleton

**6. The repository skeleton and the toolchain.** `mise.toml` pinning Zig and Bun (and Node only if P1 found it necessary), an ejected `build.zig` on P1's, `app.zon`, the Bun workspace with `@native-sdk/cli` pinned to the exact version P1 used, the frontend directory with the carried-over React UI building to a dist through whichever bundler P1 settled on, and a `tests/` tree. One Bun script builds everything, one runs every Zig test in all three passes, one runs the TypeScript tests, and one runs a named smoke suite. The script names match the current repository's wherever the thing they do is the same. `test:everything`, `what-changed`, the git hooks and the copied release workflow are all set up here, in this step, so that the very first work package is tested the way every later one will be, on every platform, from its own branch.

This is also the step that reconciles the repository against `docs/project-structure.md` from step 1. Where the skeleton has to differ from the map, the map is corrected in the same commit and the difference is called out, so the document the human approved does not quietly stop being true on the first day.

**7. The test harness and the operational scripts, ported before the thing they test.** Everything in "The operational tooling comes across, all of it" lands here or has a named work package that lands it, and the step 1 documentation lists each one with its new name. Nothing from that section waits until the end. Bring across `apps/smoke-tests/lib/runner.sh`, the control bridge, the process control library and the temp directory allocator, because they already solve the hard parts (per-test temporary directories, OS-assigned ports, recorded pids, process group cleanup, timeouts, parallel safety) and because both the desktop and the mobile suites in the current repository already drive the application through the same control bridge and the same shared test driver inside the UI. That is what makes the deduplication in step 9 possible rather than aspirational.

**8. The walking skeleton, end to end.** The real application shell: the real React UI, loaded from the embedded dist, talking to a real Zig host over the bridge, with the control bridge attached in test mode. One smoke test launches it, waits for ready, navigates, and asserts the page reached a known state, on Linux, Android and iOS.

Nothing else starts until this passes on all three. It is the equivalent of the previous plan's step 8 and it carries the same instruction: if it cannot get every platform green, the approach does not work, and that is worth knowing now rather than after fifteen packages.

**9. Fix the smoke test parity target.** The current repository has 34 UI smoke tests under `apps/desktop/smoke-tests/` and 43 under `apps/smoke-tests/tests/`. By name they share 27, with 7 desktop-only and 16 mobile-only, so the deduplicated union is 50. That number is arithmetic on directory names and is the starting point, not the answer: go through them pair by pair, confirm that a shared name is the same test rather than two different tests that happen to be numbered alike, and produce a written list of the deduplicated suite with, for each test, which platforms it runs on and why any platform is excluded. The command line suites do not dedupe: the eighty numbered tests plus the encrypted, LAN share, hash cache, sync and write lock suites all come across as they are.

## Phase 3: the shakedown

One package, ported end to end, by the real machinery, with nothing running beside it. The purpose is not the package. It is to find out what is wrong with the system while only one package's worth of work is at stake.

**The package is `fuzzy-match`** (package 12). Forty-seven lines, two functions, an existing Jest suite to port case for case, and real smoke evidence because the CLI reaches it. It is small enough that any failure is a failure of the system rather than of the work, and large enough to touch every stage. If it needs something small from `utils`, the plan takes only that.

It goes through every part of the machinery, with none of it skipped because the package is small:

- A plan written by one agent with `/plan:create`, checked by a different one with `/plan:check`, fixed with `/plan:fix`, and rechecked until clean.
- The package enters `todo/`, an implementation agent takes it in its own worktree, commits, pushes, and its branch is tested by the release workflow on every platform.
- A review agent re-runs everything itself, compares against the TypeScript on all five parts, and rejects it at least once **on purpose**, so the rejection path and the second implementation pass are both exercised rather than assumed.
- A merge train of one runs, `bun run test:everything -- --force` passes in the merge worktree, it lands on main, the worktree and branch are deleted, the parity ledger rows are updated.
- The agent records, the journal entries, the evidence directories and the decisions file are all written and pushed as it happens.
- The system is deliberately interrupted mid-package and resumed, because resume is the one path that has to work and will otherwise be first exercised during a real outage.
- An agent is deliberately wedged so the next turn notices it has stopped moving, kills it and restarts it.

**Then it stops again.** The human reads what happened: the journal, the evidence, the review's findings, the ledger, and the cost. What was clumsy gets fixed in the system, not worked around, and the fix is recorded in `docs/decisions.md`.

**Iterate one package at a time until nothing needs changing.** If the shakedown exposed problems, fix them and run a second package the same way, still alone. Repeat until a package goes from plan to merged without the system needing a change. Only then does phase 4 start. A system that needed a fix on its last single-package run is not ready to run five at once, because every problem multiplies.

**Exit criteria for phase 3**, all of which have to hold on the same run:

- A package went plan to merged with no change to the machinery and no human intervention except the checkpoint.
- The review rejected at least once and the rejection round worked.
- An interruption and a resume happened and cost one step.
- A wedged agent was noticed, killed and recovered without anything being built to do it.
- The parity ledger, journal, decisions and evidence are complete enough that the human can reconstruct the whole run without asking anything.
- The release workflow ran green on every platform for that branch.

## Phase 4: the port, as work packages

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

The port is three repositories and a set of skills, and none of them belongs inside the others. They sit under one meta repository:

```
psi-zig-port/
  claude-config/      the global skills and instructions, cloned and bootstrapped into the home directory
  photosphere-old/    the existing TypeScript repository, read-only, the source of truth for every port
  photosphere-new/    the Zig and Vercel Native repository being built
  docs/               everything about the port itself
    queues/             the pipeline: todo, in-progress, review, merge-queue, done, plus conflicts, blocked, decisions
    plans/              plans written with the plan skills, new/ then done/
    parity/             the ledger of every old-repo artefact and its counterpart
    journal/            what happened, dated, per session and per package
    decisions/          each decision, its reasoning, and every reversal appended
    interventions/      every time a human had to step in
  CLAUDE.md           the rules for working in the meta repository, including the recording rules below
```

**The meta repository does not live on any particular machine.** It is cloned onto whichever runner is executing the port, which is a droplet, a cloud session or a developer machine depending on the lane, and more than one of those at once. Everything inside it is referred to by a path relative to its root, and no absolute path to anyone's home directory appears in any file in it. A runner is set up by cloning the meta repository, cloning the three repositories inside it, and bootstrapping, in that order, from a written setup document that is itself in the meta repository.

`claude-config` is https://github.com/ashleydavis/claude-config, cloned into the meta repository and bootstrapped with its `bootstrap.sh`, which uses GNU Stow to link `home/.claude` into the runner's `~/.claude`, so the global instructions and the plan skills are present for every agent on that machine. The stowed `settings.json` is replaced with permissions set to bypass, so agents on a runner work without prompting. Everything the port does with plans uses those skills rather than inventing a format. Bootstrapping changes the global Claude configuration for every session on that machine, so on a machine the human also works on it is theirs to run, not an agent's.

`photosphere-old` is a fresh clone of the existing repository at its `mobile` branch, and it is **never written to**. It is opened, read and diffed against, and that is all. A fresh clone rather than a link to a working checkout, so that every runner sees the same tree and no agent can reach a human's uncommitted work.

Both new repositories, `psi-zig-port` and `photosphere-new`, are private.

`docs/` in the meta repository is where the port's own history lives, and it is the reason the meta repository exists at all rather than putting everything in the new repository. Plans about porting are not documentation of the ported product, and mixing them makes both worse.

### Plans, not specifications

Every package of work is a **plan**, written with `/plan:create`, checked with `/plan:check`, fixed with `/plan:fix`, and implemented with `/plan:imp`. Plans live in the meta repository under `docs/plans/new/` and move to `docs/plans/done/` when their package has merged. The skill's format is the format: overview, issues, steps, unit tests, smoke tests, verify, notes.

On top of what the skill asks for, a port plan names:

- **Source of truth**: the exact files in `photosphere-old/` being ported, by path, with line counts. The implementing agent reads all of them. Where a probe repository already prototypes the feature, its files are named too and read first.
- **Files to create** in `photosphere-new/`, by path, so that two plans can be checked for overlap before either starts.
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

- `docs/journal/` holds a dated entry per working session and per package: what was attempted, what happened, what failed and why, how long it took, what it cost.
- `docs/decisions/` holds each decision with its date, its reasoning, and its alternatives. **A decision that gets reversed is not edited: the original stays and the reversal is a new entry naming what changed and why.** The reversals are the interesting part.
- `docs/interventions/` records every time the human had to step in: what went wrong, what they did, and what would have had to be true for it not to happen.
- Each plan gets a completion note when it merges: what was built, what the review caught, how many rounds it took, and anything surprising.

**Every agent writes to the journal, and this goes in `CLAUDE.md`.** An implementation agent records what it built and what fought back. A review agent records what it rejected and why. The merge train records what it merged and what it bisected. An agent that finishes without recording anything has not finished. The rule to state in `CLAUDE.md` is that notes are written at the time, in the same commit as the work, never reconstructed afterwards.

### No shared file is ever written by two agents

With several agents running at once, any file more than one of them writes will be corrupted or will lose entries, and git makes it worse rather than better: two agents appending to the same file produce a conflict on every push, and a conflict resolved badly silently drops somebody's entry. The answer is structural, not procedural, and it is a rule rather than a convention.

**Nothing shared is appended to. Everything shared is a directory of single-writer files.**

- **The journal is a directory**, not a file. Each entry is its own file, named so two agents cannot collide: date, package, agent type and agent id. Only the agent that created an entry writes it. Nothing appends to a day's file, because there is no day's file.
- **Decisions are a directory too**, with one file per decision, and reversals are new files that name what they reverse rather than edits to the original.
- **`docs/decisions.md` is an index with one line per decision, and only the orchestrator appends to it.** Agents write the decision itself as its own file in the decisions directory; the orchestrator adds the line. The same single-writer rule covers `summary.md`. Two files in the whole repository are written by more than one agent over time, and both have exactly one writer at any moment.
- **Parity counts live per package**, in the package's own file, and are only summed into `summary.md` by the orchestrator. Two packages recording their own counts never touch the same bytes.
- **A package directory has exactly one writer at a time**, and the agent record says who it is. The orchestrator is the only exception, and only after it has killed the owner.
- **`index.md` and `detail.md` are written by the agent that owns the package**, in its stage. Nothing else edits another package's files.

**Committing concurrently needs its own care**, because a git repository has one index and one lock:

- Every commit to the meta repository stages **only the paths that agent owns**. Never `git add -A`, which sweeps up whatever another agent has half-written. This is the single most important rule in this section, because it is the one whose violation corrupts somebody else's work rather than your own.
- Because every entry is a distinct new file, rebases have nothing to conflict on. That is the property the directory-of-files design buys, and it is why it is worth the extra files.
- Agents on different runners each have their own clone, so the lock is per-clone and the remote is the meeting point. The retry on rejected push is what makes that safe.
- `photosphere-new` has no shared-file problem at all, because each package works in its own worktree on its own branch and the only place they meet is the merge train, which is single-threaded by design.

Committing is done by hand, by the agent, following one sequence every time: pull with rebase, stage only the paths that agent owns, commit, push, and retry the pull and push if the push is rejected. There is no helper script and no lock, because the design removes the contention rather than managing it: every agent writes only files that nothing else writes, so a rebase has nothing to conflict on and a retry always succeeds.

**No tooling is built for this port.** Not a queue mover, not a commit helper, not a summary generator, not a ledger builder, not a watchdog daemon. Every one of those would be another piece of software to write, test, debug and maintain, in a project whose entire purpose is porting something else, and its failures would be indistinguishable from the port's failures. Where this plan previously implied a script, it is a rule an agent follows and a file an agent edits. The only executable things in this port are the ones being ported and the ones carried over from the old repository.

### Committing and pushing as it goes

Progress has to be visible without asking anyone, at any moment, from the remote alone.

**Every write to the meta repository is committed and pushed immediately, as part of the same action that made it.** Not batched, not left for the end of a turn, not left for the end of a session. A queue move, a journal entry, a decision, an evidence file, an agent record, a package's parity counts and an edit to `summary.md` are each pushed the moment they are written. The rule is that an agent never holds an unpushed change while it goes off to do something else, because the thing it goes off to do is exactly what might kill it.

`summary.md` is edited and pushed **every time anything it shows changes**, not once a turn. A package moving queue, a review verdict, a merged train, a parity count, a package climbing the escalation ladder: each of those is a few lines changed in place and a push. The cost is a commit; the benefit is that the remote is never out of date, so the page can be read at any moment and believed.

- The meta repository is committed and pushed as plans, journal entries, decisions and notes are written. Not batched at the end of a session.
- `photosphere-new` is committed on the package branch and pushed as the work happens, so a branch under way is visible, then merged to main and pushed.
- Both use the verification hook, always. Neither is ever force pushed.

## Process machinery

Two things shape all of it.

**Every stage is driven by the orchestrator, beginning to end.** No stage waits on a person, there is no human review step in the pipeline, and there is nowhere for work to come to rest. A human reads what happened and can reverse a decision afterwards, but nothing pauses for them.

**The acceptance criteria are not invented, they are read out of the old repository.** The specification for this port already exists and is executable: it is `photosphere-old/`. Every plan's criteria are what the TypeScript does, what its tests assert, and what its docs say, so "is this right" is always answerable by opening the old file rather than by judgement.

### Queues are the state

The state lives in directories: the queue a package sits in **is** its status, and the git history of those moves is the audit log. This replaces any JSON state file, which is the thing this plan previously proposed and which is worse in every way: harder to read, easy to desynchronise, and it has no history.

`docs/queues/` in the meta repository:

```
todo/ -> in-progress/ -> review/ -> merge-queue/ -> done/
```

plus three pens beside the pipeline:

- **`conflicts/`**, a re-entry pen off `merge-queue/` for an approved package whose commits will not replay onto a main branch that moved under it. The orchestrator drains it first, every turn, without a human. A conflict is **not a failure** and counts toward nothing: main moving says nothing about the package.
**There is no `blocked/` queue, and there is no queue that waits on a person.** A package that fails goes to the **back of `todo/`** and comes round again. Nothing is ever parked, nothing waits for someone to re-admit it, and no part of the loop can come to rest with work outstanding.

That rule only works with the thing that makes it work: **coming round again means coming back differently.** A package returning to `todo/` for the third time with the same plan and the same approach is a loop, not a retry. The escalation is of approach rather than of people, and it is covered under **Failures** below.

**Decisions are taken and recorded, not queued.** Where a choice arises that a human would once have made (a divergence from the TypeScript, a route that has to change, an ambiguity in the old code), the agent decides it, writes the decision, the reasoning and the alternatives it rejected into `docs/decisions/`, and carries on. The human reads decisions afterwards and can reverse any of them, which is why reversals are first-class in that directory. A decision recorded and later reversed costs one package's rework; a decision deferred costs the whole loop stopping.

**The existence proof is always available.** Nothing in this port is unprecedented: every feature, every test and every platform already works in `photosphere-old`. When something looks impossible, the answer is in that repository, and reading how it was done there is the first move, not the last. "This cannot be done" is only ever a statement about the current approach.

Each package is a directory that moves between queues as a unit, carrying its plan and its evidence, so nothing is ever separated from its record. Split each one into an `index.md` (id, status, dependencies, failure count, one-line description) and a `detail.md` (the full plan), so a turn can read the whole board cheaply and open only what it needs.

Work the queues in this priority order: **finish what is nearest to done before starting anything new.** `conflicts/` first, then `merge-queue/`, then `review/`, then `todo/`. Otherwise reviewed work piles up behind newly started work.

### The parity ledger

This is the piece that answers the only question that matters at the end: **does the new repository match the old one?**

Counting merged packages flatters: forty merged sounds finished while a hundred test cases quietly never got ported. So progress is measured against the old repository instead, and because nothing here is generated, it is measured at a granularity that can be maintained by hand.

**Per package, in its own file, the parity record is four counts and a list.** The source files it was responsible for and how many are ported; the unit test files and cases, ported against the old repository's count; the smoke tests, by name; and the documents. Anything deliberately not ported is listed by name with its reason, which is the part that matters, because an omission with a reason is a decision and an omission without one is a mistake.

The numbers come from the old repository at the moment the plan is written, by listing the files that plan covers, and they go into the plan. So the count is established once, by the agent that has the files open anyway, rather than maintained centrally by something that has to keep scanning. The review checks the count against what was actually built, and the orchestrator copies the totals into `summary.md`.

The port is finished when every package's record is complete and the totals across them account for everything in the old repository. That total is the number reported.

### `summary.md`: the one file to read

**One file, `summary.md`, edited surgically, by one writer.** There is no generator, no data file behind it and no rendering step, because this port builds no tooling for itself: what would have been a script becomes a rule an agent follows.

- **Only the orchestrator writes it.** Subagents never touch it. They write their own files, which nothing else writes, and the orchestrator folds the outcome into the summary at step boundaries. That single-writer rule is what makes it safe while several packages are in flight, and it is the same rule everything else shared follows.
- **Changes are surgical.** Ticking a box, moving a package's status, updating a count: a few lines changed in place, never a rebuild from scratch. That is cheap whoever does it, which is what makes the no-tooling version workable.
- **It is markdown rather than structured data on purpose.** A hand-edited YAML file gets its indentation wrong eventually and takes the whole file with it. A hand-edited markdown line that goes wrong damages that line and nothing else, and the damage is visible on the page rather than at parse time.
- **The queues remain the truth.** The summary is a human-readable view over them plus the things only it carries: costs, dates, and the history of what struggled. Where the two disagree, the queues win and the summary is corrected, which is a thing to check whenever a turn has been interrupted.

For the updates to stay cheap, **every check leaves its result where it can be copied rather than worked out**: one short line beside its captured output saying what ran, the verdict and the counts. The orchestrator folds in that line. Nothing reads a test log to update the summary.

Every line starts with a checkbox. **A box is only ticked when the thing is finished**, which for a package means all of: merged to main, its parity ledger rows all accounted for, its unit tests ported case for case and passing, its smoke tests passing at the level the original repository had them, and the release workflow green on every platform for a revision containing it. Merged is not finished. Green on Linux is not finished.

What it lists:

- **Every package**, numbered as in this plan, with its checkbox, its queue, its failure count, its branch if it has one, and one line of what it is. The packages not started are listed too, because a list of only what is underway hides the size of what is left.
- **The release workflow**, job by job: 22 lines, each ticked when that job is restored, adapted and green in the new repository. This is the clearest single measure of how close the port is to being a real product, because the workflow is the definition of "this works".
- **The prototypes**, P1 to P10, each ticked when its finding is recorded and absorbed.
- **The phases and their checkpoints**, so it is obvious which one the port is in and whether it is waiting on a human.
- **The documentation set** from phase 0, file by file, ticked when it has been reconciled against what was actually built rather than when it was first written.
- **The operational scripts** carried over from the old repository, ticked when each one runs in the new one.
- **The parity totals**: accounted for against total, for source files, unit tests, smoke tests and documents separately. This is the progress number that cannot flatter, and it belongs at the top.
- **The smoke suites**: the eighty numbered CLI tests, the five other CLI suites, and the deduplicated application suite, with counts passing against counts expected, per platform.
- **Anything struggling**: every package with two or more failures, with its rung on the escalation ladder, its attempt count and the last reason. Nothing is ever parked waiting for a person, so this is the section that replaces a blocked list: it is where a package going round and round becomes visible without anyone digging.
- **Decisions taken recently**, so a decision made autonomously can be reversed before much is built on it.
- **In flight right now**: which packages have agents, of what type, on what step, and since when.
- **Cost to date**, so the number is visible rather than discovered.

The **first line of the file is the orchestrator's heartbeat**: timestamp, turn number, what it is doing now, what it expects next, and its pid, process group and runner. It is first because it is the line that says whether anything else on the page is still moving, and it is what makes an orchestrator that has stopped visible in one glance rather than by inference.

### Failures, and what is not one

Getting this taxonomy wrong is what makes an autonomous loop thrash, so it is set out exactly:

- A **failure** is any setback with the work: a check fails, an agent exhausts its budget, a review rejects, a rebase cannot be resolved, post-merge checks fail on main. Record it on the package (increment the count, write a history note saying what failed and where the evidence is) and send it to the **back of `todo/`**. It always comes back; what changes is how it is approached next time.
- An **interruption** is the run being cut off from outside: a rate limit, a killed process, a dead machine. It says nothing about the package. **Record it nowhere, count it toward nothing, and leave the queues as they are.** A package left mid-stage is re-driven from where it sits, not failed. Treating interruptions as failures marches untouched work toward the block cap, which is how an autonomous system quietly parks everything.
- A **merge conflict** in the train is not a failure either, and goes to `conflicts/`.
- A **setup or environment failure** (the toolchain will not install, a runner is broken) is **fixed, not routed around**. The environment is code: it is the runner setup document and the workflow files, both of which the port owns and can change. So the response is to fix the setup, record what was wrong in the journal, and put the packages it hit back in `todo/`. What remains banned is the *fake* fix: no substitute toolchain standing in for the pinned one, no skipped install, no borrowing another worktree's state, no test made to pass without the thing it tests. Repairing the environment is required; pretending it is repaired is not allowed.
- **Two or more packages failing the same stage or check in one turn is an environmental failure.** The shared cause is the environment, not the packages, so retrying the packages is wasted. Stop launching new work, fix the shared cause first, record it, and then let the affected packages come round again. Never respond by serialising what was parallel.

**The escalation ladder, since there is nowhere to park a package.** A package's failure count decides *how* it is attempted next, not whether it is. Each rung is tried before the next, and which rung a package is on is recorded on it:

1. **Retry.** The first failure is often the run rather than the work. Same plan, fresh agent, from the last checkpoint.
2. **Fix what the review named.** The second attempt addresses the findings specifically rather than reimplementing.
3. **Re-plan.** A third failure means the plan is wrong, so the plan is rewritten: `/plan:check` and `/plan:fix` on it with the failure history as input, by an agent that did not write it.
4. **Split it.** A plan that keeps failing is usually too big. Break it with `/plan:break` into pieces small enough that a failure names one thing.
5. **Go and read how the old repository did it.** Every one of these features already works in `photosphere-old`. Open the TypeScript, the tests around it, and its git history, and port the approach rather than inventing one.
6. **Change the route.** Different library, different arrangement, different order, a dependency built first. Record the decision and why the previous route was abandoned.

A package cycling on the same rung twice has not escalated, and that is itself the failure to catch. The rung, the attempt count and the reason are all in `summary.md`, so a package quietly going round forever is visible on the front page rather than buried.

**The reconciliation invariant is the single most valuable thing to copy.** At the end of every turn, `in-progress/` is empty. Any package still sitting there is by definition a failure nobody recorded, because no agent is working it now, so the orchestrator records and routes it itself. An agent that dies cannot file its own failure, so the loop can never depend on it doing so.

### Evidence, and never trusting a report

Also taken whole, because it is what stops an autonomous system reporting success it did not have:

- **Confidence is not evidence.** Before any claim that a check passed: identify the exact command, run it fresh, read the full output including the exit code, confirm it supports the claim, and capture it. A previous pass passing is not this pass passing. An agent's report is not a verified result.
- **One evidence directory per pass**, numbered: `implementation-1/`, `review-1/`, `implementation-2/`, and so on, plus `merge/`. Older passes are history and are never consulted to fill a gap in a newer one.
- **The latest pass proves the whole change on its own**, not just the part it altered, and everything in it is captured fresh from that pass's commit. Evidence carried forward from an earlier pass does not prove the current code.
- **Evidence never enters `photosphere-new`.** It lives in the package directory in the meta repository. Nothing is ever committed to the product repository to make a capture possible: no evidence switch, no capture helper, no test that exists to produce a screenshot. A commit in `photosphere-new` contains the port and nothing else, and the review enforces that by reading the diff.
- **Every check records the same five fields**: what was verified, how, the result, the basis for it, and on failure what to change.
- **Checks run in the foreground.** Never launch a long check in the background and end the turn waiting to be woken. A stall has to become a visible failure rather than an idle wait.

Checks come in two kinds and they are interchangeable in the pipeline: **deterministic** ones where a command decides (compile, all three Zig test passes, unit, CLI smoke, application smoke), and **judgement** ones where an agent decides against a named rule (the five-part comparison with the TypeScript, the no-globals rule, the documentation rules). They differ only in what the evidence is: command output, or a written assessment naming the rule and the code.

### Stopping and resuming

A port this long will be interrupted many times: a crashed process, a dead runner, an outage, a rate limit, credit running out mid-turn. **Resuming has to be a normal operation rather than a recovery**, and it has to work when every agent that knew what was happening is gone. The queues say which packages are in flight; they do not say what an agent was in the middle of. That gap is what this section closes.

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

- **The invocation limit is the backstop for an orchestrator that gets stuck**, and this is the strongest argument for the scheduled-turn architecture. If a turn is a scheduled invocation with a hard time limit, a turn that never ends is impossible: it is killed by the scheduler, and the next scheduled turn reads the queues and reconciles it exactly as it would after a crash. The problem stops existing rather than needing something built to solve it.

Under the long-lived architecture there is no such backstop, which is a real cost of that option: an orchestrator that gets stuck stays stuck until someone notices the summary has stopped moving.

### The review agent edits nothing

The review agent makes no code edits and commits nothing to the product repository. Its only writes are the package's own state: moving it between queues, capturing check output to its evidence directory, and on rejection a history note and a failure increment. It never fixes what it judges, because a reviewer that fixes things is an implementer with no reviewer.

It also reviews **the diff hunk by hunk against the plan**, and any change not required to implement the plan fails the review, whatever its nature.

## The implementation and review loop

One cycle per package. The orchestrator owns the loop; the agents talk only through the worktree, the plan and the notes.

1. **Orchestrator** picks the next package whose dependencies have merged, creates a branch and a worktree in `photosphere-new/`, and starts an implementation agent with the plan. Worktree and branch are named for the package and numbered, `wp-13-merkle-tree-1`, with the number rising if a package needs a second attempt, so it is always obvious what a worktree is for.
2. **Implementation agent** works only inside its worktree. It reads the named files in `photosphere-old/`, writes the Zig, writes the tests, runs them, and iterates until they pass. It commits with the hook enabled and pushes its branch as it goes. It writes its journal entry and a handover note saying what it built, what it ran, what passed, and what it could not do.
3. **Review agent** starts fresh in the same worktree with the plan and the handover note. It does not trust the note. It checks:
   - The five parts of the comparison above, with `photosphere-old/` open beside the new code. This is the main event, not a formality.
   - Every file the plan named exists, and nothing beyond the plan was changed.
   - No mutable global anywhere in the core, and no hidden state in a core library.
   - Every named unit test exists and would fail if the code were wrong. It breaks at least two on purpose and confirms they go red.
   - It runs the tests itself: all three Zig passes, the unit suite, and every smoke suite the plan named, on the platforms the plan named.
   - The repository rules are met, and the documentation and project map still match.
   - The journal entries exist and say something.
4. **If the review fails**, findings go to `review-notes.md` in the worktree as a numbered list, each naming a file, a line and what has to change, and it hands back. The implementation agent fixes and commits again. Repeat.
5. **After three rounds of the same disagreement**, the plan is what is wrong rather than the code, so the package goes to the back of `todo/` and comes back at the re-plan rung of the ladder, its worktree torn down and its history carried into the rewrite. If the disagreement is a choice rather than a defect, the reviewer decides it, records it in `docs/decisions/` with the alternatives it rejected, and the work continues under that decision.
6. **When the review passes**, the package moves to `merge-queue/`. It is not merged by the review agent and not by the implementation agent.

Several packages may be in flight when their dependencies have merged and the file sets their plans declare are disjoint. The orchestrator works the queues in priority order every turn (`conflicts/`, `merge-queue/`, `review/`, `todo/`) and ends the turn with `in-progress/` empty, reconciling anything left there as an unrecorded failure.

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

## What "complete" means

Parity is not a judgement call. The port is complete when all of these are true at once, on a single revision of the main branch:

- Every package matches its TypeScript counterpart on all five parts of the comparison above, and where it does not, the divergence document says so and the human has accepted it.
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

The work divides by what a runner has to have. These are requirements, not machines, and any host that meets a class can serve it:

- **Headless.** Linux, the pinned toolchain, the S3 emulator, network access to fetch dependencies, and credentials to push. No display, no GPU, no virtualisation. Covers Zig compilation, all three test passes, every unit test, all the CLI smoke suites, and the command line tool built for all four desktop targets from that one runner, because a pure Zig binary cross-compiles, which `what-changed` does today. This is most of the port by volume and all of packages 10 to 33, and it is the class the cloud environment and a plain droplet both satisfy.
- **Linux desktop.** Everything above plus GTK4, WebKitGTK 6.0 and `xvfb`. Runs the application smoke suite on Linux. A droplet satisfies this once the packages are installed; a headless container may not, and whether it does is a question the setup work has to answer rather than assume.
- **Android.** A machine that can run an emulator at usable speed, which means KVM. `ls -l /dev/kvm` on the candidate host is the check, run at the moment the host is provisioned and never assumed, because standard droplets are not guaranteed to expose it. If a droplet cannot, a provider that offers nested virtualisation or bare metal is the answer.
- **macOS.** A macOS host with Xcode, for the macOS desktop build and for everything iOS. This is the one class that cannot be provisioned from a Linux droplet at all, so it is either a hosted Mac runner or a Mac the port can reach.
- **Windows.** A Windows host with the WebView2 runtime, for the Windows desktop build and its smoke suite. Needed because the SDK builds on the target operating system.

### The release workflow already provides every runner class

`.github/workflows/release.yml` in the current repository is 1,744 lines and 22 jobs, and between them those jobs already run on every runner class this port needs: `ubuntu-latest` and `ubuntu-24.04` for the headless work, `windows-latest`, `macos-15-intel`, `macos-latest` and `macos-14`, and the Android emulator on `ubuntu-latest`, which the `android-smoke-tests` job enables KVM for with a udev rule before booting an AVD. **That settles the question the Android lane was open on: GitHub's Linux runners expose KVM, so the Android suite does not need a droplet or bare metal.** iOS unit and smoke tests already run on `macos-14`.

Two consequences. The port has hosted runners for all five classes without buying or hosting anything, and the pinned Xcode 14.2 environment is a constraint on local development rather than on CI, which already builds and tests iOS on a newer macOS image. That makes a negative result from prototype P2 less severe than it first looks: it costs local iOS development, not the iOS platform.

### Two architectures for running it

Both do the same work and use the same queues, plans, evidence and records. They differ in what keeps the loop turning, and that difference decides what has to be hosted. **Neither is chosen here.** The choice is made once the two unknowns in architecture B have been checked, and whichever is chosen, the other stays valid as a fallback, because nothing in the process design depends on either.

**Architecture A: a long-lived host.**

- A DigitalOcean droplet runs the orchestrator continuously, one turn after another.
- The droplet serves the headless class itself and the Linux desktop class once its packages are installed.
- The other classes are reached by pushing branches and letting the release workflow test them on GitHub-hosted runners.
- **What it needs**: one droplet, provisioned from the setup document, with credentials to push and a schedule or loop script that keeps invoking turns.
- **Strengths**: nothing about it is uncertain. A process that runs continuously can hold long operations, watch its own children, and keep the emulator pool up between turns. It is the architecture the rest of this plan is written against.
- **Costs**: a machine to pay for and maintain, and no backstop for an orchestrator that wedges, since nothing is built to watch it. It stays wedged until the summary is noticed to have stopped moving.

**Architecture B: short scheduled turns, no long-lived host.**

- The only structural job the droplet does is being always-on. That need disappears if a turn is short, stateless and idempotent, which the resume design already requires for crash recovery.
- Each turn becomes an externally scheduled invocation with a hard time limit. A scheduled GitHub Actions workflow starts a turn, the turn reads the queues, does one unit of work, commits, pushes and exits.
- **The scheduler is the backstop, so nothing has to be built to be one**: an agent that wedges dies when its invocation hits the limit, and the next scheduled run reconciles it from the queues exactly as it would after a crash. That is the same path as resume, so it gets exercised constantly rather than only in emergencies. Given that no tooling is being written, this is the stronger of the two architectures.
- GitHub Actions also brings the macOS and Windows classes with it, and the Android class through KVM on its Linux runners.
- **What it needs**: nothing hosted at all.
- **Two things to check before committing to it**: whether remote Claude sessions are available on the account and can reach the network to fetch Zig, the SDK and the C dependencies and push to private repositories; and whether a useful turn fits inside both Claude's limits and the runner's job limit.
- **Costs**: a turn that cannot finish a long operation has to be able to leave it for the next turn, which puts more weight on the checkpointing than architecture A does. Long device suites are the awkward case, since they may exceed a job limit.

**How they combine.** The two are not exclusive: the sane end state is probably B for the loop and A for anything that has to be long-lived, if such a thing turns out to exist. Either way the release workflow does the multi-platform testing, so no architecture has to solve macOS, Windows or Android by hosting them.

The consequence, whichever is chosen: **the system converges to everything green except the classes it has no runner for.** Since the release workflow already covers all five, that should be nothing, and if a class does go missing the packages needing it queue up while everything else keeps moving.

### Setting it up

1. **Do the cold start**, exactly as set out in the section of that name. An agent creates both repositories and everything in them; the only human action in the whole port up to this point is supplying the Claude credentials the scheduled turns run under.
2. **Step 1 of the port runs, and then waits for a human.** An agent writes `photosphere-new`'s `CLAUDE.md` and the whole documentation set and stops. The human reads them and accepts or changes them, `docs/project-structure.md` first and hardest, because every plan is written against it. Nothing else starts until that acceptance is recorded. The unattended system inherits whatever is in these files, which is why this is the one review that cannot be delegated.
3. **Phase 1 runs once the prototype findings exist.** The prototypes are built outside this plan; phase 1 is where the port absorbs them. Every decision that comes out of a negative result is escalated and recorded, not taken by an agent.
4. **Provision the runners**: the droplet or the cloud sessions for the headless lane, with mise, the Zig and Bun versions the prototypes pinned (plus Node if P1 found the SDK CLI needs it), the GTK4 and WebKitGTK 6.0 development packages, `xvfb`, the C library build dependencies, GNU Stow for the bootstrap, and the S3 emulator. Confirm the pinned toolchain installs from a clean machine and write down the exact commands, because that list is also what a new developer needs.
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
- Skip, disable or weaken a test to make a package pass. A failing test that cannot be fixed is an escalation.

## Risks, in the order they can bite

None of these is a risk to the port happening. Each is a risk to a route, and each one's entry says what the alternative route is.

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
- **The two probe repositories are the port's best reference material and are the opposite of the abandoned worktree below**: they are small, they were built and run, and they cover exactly the parts of this application that meet the WebView. https://github.com/ashleydavis/electron-alternative-vercel-native is the one this plan builds on, and https://github.com/ashleydavis/electron-alternative-zig-with-webview solves the same problem against the raw `webview` C binding, which makes its message queue and its comparison section worth reading even though the port does not use it. The probes' own conclusion is the useful one: the hard parts (the threading rule, range requests, the WebSocket lifecycle) belong to the WebView model rather than to whichever wrapper is chosen, so they carry over whatever happens to the SDK.
- **The abandoned worktree in this repository is reference material and nothing more.** `.claude/worktrees/zig-core-port` holds roughly 27,000 lines of Zig across sixteen module directories with about 1,030 test blocks, plus seven spikes. None of it is committed, none of it has been verified to build or pass, and it was written against a superseded design that assumed a parallel tree beside the TypeScript. Read it before porting a module it already covers, particularly the `s3` and `napi` spikes, and treat nothing in it as done. Do not work in it and do not merge it.
- **This plan is transient.** Nothing that outlives the port may reference it. Anything in here worth keeping (the writing rules, the divergence list, the toolchain versions, the packaging steps) gets copied into the new repository's own permanent documents, in full, at the point it is needed.
