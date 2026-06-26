# Mobile JS-Engine Testbed: Run Compiled TS Under a Native-Embedded Interpreter

## Overview
This plan builds a standalone prototype that proves one idea: compiled TypeScript can run under a JavaScript interpreter embedded in native code inside a Capacitor app, on both Android and iOS, driven from native (not the WebView). It contains no Photosphere code. It starts from the existing example Capacitor app at `/home/ash/projects/photosphere/capacitor-example` (Capacitor 5.7.8, plain JS, `webDir: src`, with working `android/` and `ios/` native projects) and adds: a TypeScript source file compiled to a single JS bundle, a custom Capacitor plugin we write, and native code that loads the bundle into an embedded interpreter (JavaScriptCore on iOS, QuickJS on Android), runs an exported function off the WebView, and returns the result to the UI. Success is the same compiled bundle producing the same result through the native interpreter on both platforms.

The prototype is a copy of the example app, kept separate so the example stays untouched. Target directory: `/home/ash/projects/photosphere/js-engine-testbed`.

## Issues
<!-- Populated later by plan:check -->

## Scope
- In scope: embedding an interpreter in native code, loading a compiled-TS bundle, calling an exported function from native, passing input in and getting a result out, a native host shim the JS can call back into, and an automated test that runs the exact bundle in QuickJS.
- Out of scope: any Photosphere code, storage backends, file serving, image/video tooling, and running while the app is suspended (background scheduling). Those are separate plans. This proves only that the interpreter approach works.

## Interpreter Hosting Options (ranked, with fallbacks)
The testbed must not bet on a single interpreter. Each native side is built behind a small runner interface (`evaluate(bundleSource)`, install `host`, `callRunTask(input)`), so the engine behind it can be swapped without touching the plugin or the bundle. If the primary fails to embed, build, or run the bundle, drop to the next option on that platform.

iOS, in order to try:
- JavaScriptCore (primary): Apple system framework, no dependency, mature, gets JIT. Lowest risk.
- QuickJS (fallback 1): small C interpreter compiled for iOS, embedded directly. Used if we want the same engine on both platforms.
- Hermes (fallback 2): embeddable engine from the React Native project; heavier to integrate.

Android, in order to try:
- QuickJS via a prebuilt JNI binding (primary): small, embeddable, modern-enough JS support.
- Duktape via JNI (fallback 1): another small C interpreter with mature Android bindings.
- Hermes (fallback 2): shipped as an AAR; larger but well supported.
- J2V8 / V8 (fallback 3): full V8, largest footprint, strongest performance.
- Rhino (last resort): pure-JVM, no NDK, simplest to add, but ES5-era language support, so the bundle would need an ES5 target.

Cross-platform simplification (optional): QuickJS on both iOS and Android, or Hermes on both, gives one engine family to reason about. Listed as an option, not the default, because JavaScriptCore on iOS is the lowest-risk starting point.

The plan proves the idea as soon as any one engine per platform runs the bundle. The fallbacks exist so a single engine's embedding or build trouble does not block the prototype.

## Interpreter Hosting Options (ranked, with fallbacks)
The testbed must not bet on a single interpreter. Each native side is built behind a small runner interface (`evaluate(bundleSource)`, install `host`, `callRunTask(input)`), so the engine behind it can be swapped without touching the plugin or the bundle. If the primary fails to embed, build, or run the bundle, drop to the next option on that platform.

iOS, in order to try:
- JavaScriptCore (primary): Apple system framework, no dependency, mature, gets JIT. Lowest risk.
- QuickJS (fallback 1): small C interpreter compiled for iOS, embedded directly. Used if we want the same engine on both platforms.
- Hermes (fallback 2): embeddable engine from the React Native project; heavier to integrate.
- Duktape (fallback 3): small C interpreter, ES5-era support, simple to embed.

Android, in order to try:
- QuickJS via a prebuilt JNI binding (primary): small, embeddable, modern-enough JS support.
- Duktape via JNI (fallback 1): another small C interpreter with mature Android bindings.
- Hermes (fallback 2): shipped as an AAR; larger but well supported.
- J2V8 / V8 (fallback 3): full V8, largest footprint, strongest performance.
- Rhino (last resort): pure-JVM, no NDK, simplest to add, but ES5-era language support, so the bundle would need an ES5 target.

Cross-platform simplification (optional): QuickJS on both iOS and Android, or Hermes on both, gives one engine family to reason about. Listed as an option, not the default, because JavaScriptCore on iOS is the lowest-risk starting point.

The plan proves the idea as soon as any one engine per platform runs the bundle. The fallbacks exist so a single engine's embedding or build trouble does not block the prototype.

## Steps

1. Copy the example app to the testbed directory. Duplicate `/home/ash/projects/photosphere/capacitor-example` to `/home/ash/projects/photosphere/js-engine-testbed` (excluding `node_modules`, `.git`, `android/build`, `android/.gradle`). In the copy, set `package.json` `name` to `js-engine-testbed`, and set `appId` to `com.example.jsenginetestbed` and `appName` to `js-engine-testbed` in `capacitor.config.json`.

2. Add TypeScript and a bundler to the testbed. Add `typescript` and `esbuild` as devDependencies. Add a `tsconfig.json` targeting `ES2017`, `module: ESNext`, `strict: true`, `outDir` unused (esbuild does the emit). Add npm scripts: `build:bundle` (esbuild bundles the task entry to a single IIFE JS file), and wire `build:bundle` to run before `cap sync` in the existing `android` / `ios` / `run-android` / `run-ios` scripts.

3. Write the task source in TypeScript (no Photosphere code). Create `task/src/task.ts` containing a small but non-trivial pure function written fresh for the testbed, for example `levenshtein(a: string, b: string): number` and a `runTask(input: ITaskInput): ITaskResult` entry that uses it. Define named interfaces `ITaskInput` and `ITaskResult`. `runTask` also calls a host function (see step 4) to prove the native-to-JS bridge, e.g. it asks the host for a string via `host.getInput()` and returns the computed distance plus an echo of a value the host supplied.

4. Define the host bridge contract. In `task/src/host.ts` declare the interface the embedded JS expects the native side to provide on a global object `host`: `host.log(message: string): void` and `host.getInput(): string`. The bundle references `globalThis.host`. Document that native must install `host` before invoking `runTask`.

5. Build the bundle. Configure esbuild to bundle `task/src/task.ts` into `src/assets/task.bundle.js` as a single IIFE that assigns the entry to a global, e.g. `globalThis.Task = { runTask }`. No external imports, no Node built-ins. Copy `task.bundle.js` into the web assets (`src/assets/`) so both the WebView and the native projects can read the same artifact.

6. Make the bundle available to the native projects. After `build:bundle`, copy `src/assets/task.bundle.js` to `android/app/src/main/assets/task.bundle.js` and `ios/App/App/task.bundle.js`, and ensure the iOS file is added to the app target as a bundle resource. Add a `copy:bundle` npm script and chain it after `build:bundle`.

7. Create the custom Capacitor plugin (JS side). Add `src/js-engine-plugin.js` that uses `registerPlugin('JsEngine', ...)` and exposes `runTask(options)` returning a promise. Define the plugin so the WebView calls native, native runs the bundle in the interpreter, and the result returns to JS.

8. Define the native runner interface on both platforms first, so the interpreter is swappable per the Interpreter Hosting Options section. On iOS declare a Swift protocol `JsRunner` with `evaluate(_ source: String)`, `installHost(...)`, and `callRunTask(_ input:) -> result`. On Android declare a Kotlin interface `JsRunner` with the same shape. The Capacitor plugin talks only to `JsRunner`, never to a concrete engine, so dropping to a fallback engine means adding one new runner class, not touching the plugin or bundle.

9. Implement the iOS plugin and the primary JavaScriptCore runner. Add `ios/App/App/JsEnginePlugin.swift` (a `CAPPlugin` with a `runTask` method that calls `JsRunner`) and `ios/App/App/JscRunner.swift` conforming to `JsRunner`. The runner creates a `JSContext`, installs the `host` object (`log`, `getInput`) as native closures, evaluates the contents of `task.bundle.js`, then calls `globalThis.Task.runTask(input)` with the input marshalled from the plugin call, and returns the result back through the plugin to the WebView. Register the plugin in the iOS bridge. If JavaScriptCore cannot run the bundle, add a fallback runner (QuickJS, then Hermes, then Duktape per the options section) implementing the same `JsRunner`.

10. Implement the Android plugin and the primary QuickJS runner. Add the QuickJS JNI binding dependency to `android/app/build.gradle` (a prebuilt QuickJS-for-Android artifact). Add `android/app/src/main/java/com/example/jsenginetestbed/JsEnginePlugin.kt` (a `@CapacitorPlugin` with a `runTask` method that calls `JsRunner`) and `QuickJsRunner.kt` implementing `JsRunner`. The runner creates a QuickJS context, installs the `host` object (`log`, `getInput`) as native callbacks, evaluates `task.bundle.js` read from assets, calls `globalThis.Task.runTask(input)`, and returns the result through the plugin. Register the plugin in the Android `MainActivity` / plugin list. If QuickJS cannot be embedded or run the bundle, add a fallback runner (Duktape, then Hermes, then J2V8, then Rhino per the options section) implementing the same `JsRunner`.

11. Build the WebView UI to drive it. Edit `src/index.html` and `src/index.js` to add a button that calls `JsEngine.runTask({ a: "kitten", b: "sitting" })`, and an element that displays the returned result (the distance and the host echo). On load, also show which platform/engine answered so the two platforms are visually distinguishable.

12. Wire the run scripts. Confirm `npm run run-android` and `npm run run-ios` first build and copy the bundle, then `cap sync`, then launch. Add a `README.md` in the testbed describing the one idea being proven and how to run each platform.

## Unit Tests
- `task/test/task.test.ts`: test the pure `levenshtein` function against known pairs (`"kitten"`/`"sitting"` is 3, identical strings 0, empty-string cases), run under Bun. Proves the task logic is correct independent of any engine.
- `task/test/run-task.test.ts`: call `runTask` with a mocked `globalThis.host` (stub `log` and `getInput`) and assert the returned `ITaskResult`. Proves the entry point and host bridge contract work in plain JS.

## Smoke Tests
- `task/test/quickjs-parity.test.ts`: load the built `src/assets/task.bundle.js` into QuickJS using the `quickjs-emscripten` package (QuickJS compiled to WASM, runs in Bun/Node), install a mock `host`, call `globalThis.Task.runTask(...)`, and assert the same result the unit test expects. This automatically proves the exact shipped bundle runs under the same interpreter family used on Android, with no device required.
- A shell smoke script `scripts/smoke.sh` (invoked via an npm script) that: runs `build:bundle`, asserts `src/assets/task.bundle.js` exists and is non-empty, runs `copy:bundle`, and asserts the bundle now exists at both the Android assets path and the iOS app path. Captures the build-and-wire pipeline as an automated check.
- Native build checks (see Verify): the iOS and Android projects must compile with the new plugin and runner files. The on-device run via `cap run` is the final acceptance for each platform; the QuickJS parity test is the automated stand-in for the engine-execution claim, and the iOS JavaScriptCore path is covered by the iOS build plus the device launch.

## Verify
- Run the task unit tests (Bun) and confirm all pass.
- Run the QuickJS parity smoke test and confirm the built bundle returns the expected result under QuickJS.
- Run `scripts/smoke.sh` and confirm the bundle builds and lands at both native paths.
- Build the Android project (`npm run android` through `cap sync` and a Gradle assemble) and confirm it compiles with the QuickJS dependency and the new Kotlin plugin.
- Build the iOS project (`cap sync` and an `xcodebuild` compile of the App target) and confirm it compiles with the new Swift plugin.
- Launch on each platform (`npm run run-android`, `npm run run-ios`), press the button, and confirm the displayed result matches the unit-test expectation, proving the compiled TS ran under the native interpreter on the device.

## Notes
- The custom Capacitor plugin here is our own code, not a third-party plugin, which fits the no-third-party-plugins constraint from the background-tasks plan. The one external native dependency is the Android QuickJS binding (a native library, not a Capacitor plugin); iOS uses the system JavaScriptCore framework, so it needs no dependency. If the Android binding proves troublesome, a pure-JVM fallback (Rhino) can prove the same idea, at the cost of older language-feature support, which is why the bundle targets ES2017 and avoids exotic syntax.
- The interpreter runs the JS off the WebView, in native-owned context, which is the property that a later background-execution plan would build on. This testbed deliberately stops short of background scheduling so it proves exactly one thing.
- esbuild is chosen over tsc-only because the native side needs a single self-contained JS file with no module system; a bundled IIFE assigning to a global is the simplest thing both JavaScriptCore and QuickJS can evaluate.
- `quickjs-emscripten` is the key to making the engine-execution claim automatically testable without a device or simulator in CI.
</content>
