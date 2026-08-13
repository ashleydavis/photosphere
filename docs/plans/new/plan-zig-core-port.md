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

**P2. iOS under macOS 12.7.6 and Xcode 14.2.** The local Apple environment is pinned to those versions, which is why the current repository is stuck on Capacitor 5. Vercel Native generates an Xcode project and expects `xcodebuild -scheme <app> archive` to work with no hand edits, its mobile support is vendor-labelled experimental, its mobile documentation page is a 404, and nothing in the probe has ever been built for a phone.

It answers usefully when a generated project builds, installs and launches on the simulator from the pinned toolchain, a bridge command returns a value, an emitted event reaches the page, and a loopback socket can be bound and reached from the WebView, since the asset server depends on that. If it does not build, the exact error matters more than the conclusion.

The choice that follows a negative result is the human's: raise the Apple toolchain and lose local iOS development on the current Mac, get a newer Mac, or ship iOS later than the other platforms. The port continues either way; what changes is which packages have an iOS lane.

**P3. Android through the SDK's own toolchain.** The same three things through `native dev --target android`, installed on an emulator. It answers usefully when it also reports how the SDK's emulator handling interacts with an existing pool, because the pool and its monitor belong to the human and the port must not fight them.

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
- Port what is used, not what exists. A function nobody calls, an option nobody passes and a branch nothing reaches are all behaviour with no test to hold them honest. Where a subset is ported, the file says at the top what was left out and why, by name.
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
- **How to port a library you cannot copy.** Its header says it is "an implementation of what is used, not of commander", lists by name what is missing on purpose (short flags, boolean flags, value parsers, `.requiredOption`, `.hook`, `opts()` inheritance, variadic and negatable options) and gives the reason: each one would be behaviour with no test to hold it honest. What it does reproduce exactly is the wording of the errors and the layout of the help, because the smoke tests assert on both.
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
- **The whole Android emulator pool.** `scripts/android-pool-status.sh`, `apps/android-frontend/scripts/emulator-pool-monitor.sh`, `emulator.sh`, `emulator-config.sh`, `emulator-status-lib.sh`, `android-env.sh`, `psphere-pool.slice`, the pool repair and diagnose commands, and the rolling monitor logs. This took a long time to get right, it is what makes Android testing possible at all, and it is entirely independent of what the application is written in. It comes across whole, along with the rules about who may start, stop and repair it.
- **`scripts/lib/`**: the temp directory allocator, the process control library with `kill_process_tree` and `kill_process_group`, the concurrency helpers and the timeout helper. Every parallel-safety rule in this repository is enforced by these four files.
- **The smoke test harnesses**: `apps/smoke-tests/lib/runner.sh`, the control bridge, `android.sh`, `ios.sh`, the Android lock, and the `common.sh` files from all three suites. Deduplicated where the desktop and mobile versions do the same job, never dropped.
- **`scripts/run-mobile-tests.sh`, `scripts/android-smoke-tests-ci.sh`** and the mobile lock and status commands.
- **`scripts/s3-emulator.sh`, `scripts/seed-s3-bucket.ts`, `scripts/s3-object.ts`, `scripts/clear-s3-bucket.js`.** The S3 tests need real infrastructure and this is it.
- **`scripts/story-player.sh`** and the stories runs on Electron, Android and iOS, which become runs against the new shell on desktop, Android and iOS. Rendering every page at phone resolution is how mobile layout problems get found.
- **The media tool scripts**: `fetch-mobile-media-tools.sh`, `update-mobile-media-tools.sh` and their documents, adjusted to whatever prototype P7 settles for bundling ImageMagick and ffmpeg.
- **`scripts/measure-android-emulator-leak.sh`** and the performance and benchmark runs, plus the perf budgets that fail a build when a stage gets slower.
- **The test fixtures**: `test/dbs/` and every checked-in database, image and video the suites point at. The Zig side needs them more than the TypeScript did, because they are the evidence that the ported formats match.

Two rules that go in `CLAUDE.md` about this: a work package may improve one of these scripts but may not delete or replace one without the human saying so in that message, and the review agent checks that any script a package touched still runs. If something here turns out to have no place in the new repository, that is a finding to report, not a decision to take.

## Phase 0: the rules and documentation checkpoint

**1. Create the new repository, write its `CLAUDE.md` and its entire documentation set, and then stop and wait.**

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

**6. The repository skeleton and the toolchain.** `mise.toml` pinning Zig and Bun (and Node only if P1 found it necessary), an ejected `build.zig` on P1's, `app.zon`, the Bun workspace with `@native-sdk/cli` pinned to the exact version P1 used, the frontend directory with the carried-over React UI building to a dist through whichever bundler P1 settled on, and a `tests/` tree. One Bun script builds everything, one runs every Zig test in all three passes, one runs the TypeScript tests, and one runs a named smoke suite. The script names match the current repository's wherever the thing they do is the same. `test:everything`, `what-changed` and the git hooks are set up here, in this step, so that the very first work package is tested the way every later one will be.

This is also the step that reconciles the repository against `docs/project-structure.md` from step 1. Where the skeleton has to differ from the map, the map is corrected in the same commit and the difference is called out, so the document the human approved does not quietly stop being true on the first day.

**7. The test harness and the operational scripts, ported before the thing they test.** Everything in "The operational tooling comes across, all of it" lands here or has a named work package that lands it, and the step 1 documentation lists each one with its new name. Nothing from that section waits until the end. Bring across `apps/smoke-tests/lib/runner.sh`, the control bridge, the process control library and the temp directory allocator, because they already solve the hard parts (per-test temporary directories, OS-assigned ports, recorded pids, process group cleanup, timeouts, parallel safety) and because both the desktop and the mobile suites in the current repository already drive the application through the same control bridge and the same shared test driver inside the UI. That is what makes the deduplication in step 9 possible rather than aspirational.

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
| 47 | Documentation reconciliation: every document from step 1 checked against what was built, the project map updated to the tree as it exists, third party notices completed with every linked C library and its licence, and the `// Port of ...` header lines removed now that the correspondence has served its purpose | all | The project map matches the repository file for file; no document describes intent that was never built; no comment points at a repository the reader cannot open |

Two things about the command line packages, because they are five entries in the table and one decision underneath:

- **The `commander` port already exists.** `what-changed`'s `src/lib/commander.zig` is the subset of `commander` that a command line tool uses, in Zig, with the error wording and help layout reproduced exactly because its smoke tests assert on them. Photosphere's CLI is written against `commander` as well. Package 25 lifts that file, extends it to whatever Photosphere's command line uses that `what-changed`'s does not, and extends the deliberate-omission list at the top of the file in the same edit. It does not start again.
- **The CLI layout follows the same tool**: `src/main.zig`, one file per command under `src/cmd/`, shared code under `src/lib/`, tests in the files they test. The smoke suites drive the built executable rather than the source, which is the convention that tool adopted for the reason that what ships gets tested rather than trusted.

Not ported, for the same reasons as before: the Model Context Protocol integration, which has no Zig equivalent and stays TypeScript in whatever form the shell can host, and the React UI itself.

## The work package contract

Every package of work handed to a subagent is a written specification, checked into `automation/packages/<id>.md` in the new repository, and it contains all of:

- **Goal**, in one paragraph: what exists after this and did not exist before.
- **Source of truth**: the exact list of files in the old repository being ported, by path, with their line counts. The implementation agent reads all of them. Where the probe repository already prototypes this package's feature (see the table above), its files are named here too and are read first, because they are working code against the SDK where the old repository's equivalent is code against Electron or Capacitor.
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

- **The headless lane**: Zig compilation, all three test passes, every unit test, and all of the CLI smoke suites. Needs Linux, a toolchain, and the local S3 emulator. No display, no GPU, no virtualisation. This is most of the port by volume and all of packages 10 to 33. It also builds and tests the command line tool for all four desktop targets from that one Linux machine, because a pure Zig binary cross-compiles, which `what-changed` does today.
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
3. **Have the prototype findings in hand**, and run phase 1 with a human watching. The prototypes are yours and are built outside this plan; phase 1 is where the port absorbs them, and every decision that comes out of a negative result is yours rather than an agent's.
4. **Provision the runners**: the droplet or the cloud sessions for the headless lane, with mise, the Zig and Bun versions the prototypes pinned (plus Node if P1 found the SDK CLI needs it), the GTK4 and WebKitGTK 6.0 development packages, `xvfb`, the C library build dependencies, and the S3 emulator. Confirm the pinned toolchain installs from a clean machine and write down the exact commands, because that list is also what a new developer needs.
5. **Write the work package specifications** for at least packages 10 to 20 before starting the loop. The loop consumes specifications faster than it produces them, and an agent writing its own specification is an agent marking its own homework.
6. **Set up the orchestrator.** Two ways, and the second is the fallback for the first:
   - A slash command in the new repository (`/port:next`) that performs exactly one cycle of the loop above and exits, driven on a schedule so that each tick picks up wherever the last one stopped. Scheduling can be a cron entry created from inside a session or a plain system cron calling headless mode.
   - A shell script on the droplet in a loop, calling Claude Code in headless mode with the same command, one cycle per invocation, sleeping between cycles.
   Either way the unit of work is one cycle, not one package and never the whole port, so a crashed or killed process loses one cycle.
7. **Keep the state outside the agent.** `automation/state/packages.json` in the repository holds, per package: status (ready, in progress, in review, blocked, merged), the branch, the worktree path, the round count and the last finding. The orchestrator reads it at the start of a cycle and writes it at the end. An agent's memory of what it was doing does not survive a restart; a file does.
8. **Set the escalation path.** Three failed review rounds, a failed merge, a red suite on the main branch, or anything that contradicts a prototype finding stops that package and notifies you. A push notification or a message to a session you watch is enough. Everything else keeps running.
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
