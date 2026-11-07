# Adding native functions on iOS

There are two separate ways to add native behaviour. Pick by who needs it.

- The background worker (the embedded JS engine) needs a Node-style function (file, crypto, network): add a **host bridge function**.
- The app UI (the WebView) needs a device feature (pick a file, keychain): add a **Capacitor plugin method**.

They are different systems. Do not mix them up.

All iOS native code lives under `apps/ios-frontend/ios/App/App/`. The engine code is in the `JsEngine/` subfolder.

## 1. Host bridge function (for the background worker)

The worker runs JavaScript in JavaScriptCore. It calls native code through a global object called `host`, for example `host.fsReadFile(path)`. Calls are synchronous: JS calls in, native returns a value straight back.

You touch these files:

1. `JsEngine/HostBridge.swift` — add the implementation, and register it inside `install(into:)`.
2. `packages/mobile-worker/src/lib/host-functions.ts` — add the name to the `IHost` interface and to the `EXPECTED_HOST_FUNCTIONS` list. The list is what makes a missing native version fail loudly instead of silently.
3. `packages/mobile-worker/src/shims/…` — call it from the shim that needs it. Then rebuild the bundle (see below).

### The registration to copy

Inside `HostBridge.install(into:)`, each function is a Swift closure stored on the `host` object:

```swift
let myThing: @convention(block) (String) -> JSValue = { [weak self] value in
    guard let self = self else { return JSValue(nullIn: context) }
    do {
        return JSValue(object: try self.myThing(value: value), in: context)
    }
    catch {
        return JSValue(object: HostBridge.hostErrorEnvelope(error), in: context)
    }
}
host.setValue(JSValue(object: myThing, in: context), forProperty: "myThing")
```

Functions that return a simple value can use a plain Swift return type instead of `JSValue` (for example `fsAccess` returns `Bool`).

### Passing data

- Types that cross cleanly: `String`, `Bool`, `Int`. Use `JSValue(nullIn: context)` for null.
- File contents cross as **base64 strings** (`data.base64EncodedString()` out, `Data(base64Encoded:)` in).
- Structured data crosses as a **JSON string** you build by hand (see `fsStat`). Use `HostBridge.jsonEscape(...)` for any string field.

### Reporting errors

Do not throw across the bridge. Return the error envelope string `@@HOSTERR@@<code>:<message>` via `HostBridge.hostErrorEnvelope(error)`. The JS side turns it back into a normal error with a Node-style `error.code`. (A native exception would crash the Android engine, which is why both platforms use this string convention.)

### The JS side

Add the function to the `IHost` interface and the `EXPECTED_HOST_FUNCTIONS` array in `packages/mobile-worker/src/lib/host-functions.ts`, then call it from a shim through `callHost(() => host.myThing(...))`.

## 2. Capacitor plugin method (for the app UI)

The UI talks to native features through Capacitor plugins. The main one is `JsEnginePlugin` (`JsEngine/JsEnginePlugin.swift`), registered under the JS name `"JsEngine"`. File picking lives here as `pickFiles`.

### The method to copy

```swift
@objc func myMethod(_ call: CAPPluginCall) {
    guard let value = call.getString("value") else {
        call.reject("myMethod requires value")
        return
    }
    // ... do the work ...
    call.resolve()                       // or call.resolve(["paths": paths])
}
```

Read inputs with `call.getString(...)` / `call.getValue(...)`. Return with `call.resolve(...)`, fail with `call.reject(...)`.

### The part that is easy to miss

Capacitor cannot see your Swift method on its own. Each plugin has a companion Objective-C `.m` file that lists its methods. Add a line for yours in `JsEnginePlugin.m`:

```objc
CAP_PLUGIN(JsEnginePlugin, "JsEngine",
    CAP_PLUGIN_METHOD(pickFiles, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(myMethod, CAPPluginReturnPromise);
)
```

A method missing from the `.m` file is invisible to JS, even though the app still builds.

### Anything that shows UI (like a file picker)

UIKit must run on the main thread. Present it with `DispatchQueue.main.async`, and if you resolve later from a delegate, hold onto the `CAPPluginCall` (see how `pickFiles` keeps `pendingPickCall`).

### The JS side

The plugin's interface is `IJsEnginePlugin` in `packages/mobile-frontend/src/lib/js-engine-plugin.ts`. Add your method there. App code usually wraps it in a plain function in `mobile-platform-tasks.ts` (like `pickMobileFiles`).

### A brand-new plugin

Create `MyPlugin.swift` (`@objc(MyPlugin) public class MyPlugin: CAPPlugin`) and `MyPlugin.m` (`CAP_PLUGIN(MyPlugin, "My", ...)`), add both files to the Xcode project, and on the JS side `registerPlugin<IMyPlugin>("My")`. The name in `CAP_PLUGIN(..., "My", ...)` and in `registerPlugin("My")` must match exactly. Capacitor finds `CAP_PLUGIN` classes automatically, so there is no list to update.

## After changing worker shims: rebuild the bundle

The worker JS is a build artifact: it is generated at build time and is not committed to git. `bun run sync` builds and copies it (so `bun run open`, `bun run run`, `bun run test:ios`, `bun run test:ios:unit`, `bun run build:ios`, and the story player all regenerate it). After editing anything in `packages/mobile-worker/src/`, do just the bundle step:

```
bun run bundle:worker
```

(run from `apps/ios-frontend`). This regenerates `apps/ios-frontend/ios/App/App/worker.bundle.js`.

## Adding files to the Xcode project

New `.swift`, `.m`, and resource files must be added to `apps/ios-frontend/ios/App/App.xcodeproj/project.pbxproj` (code in the Sources phase, the worker bundle in the Resources phase), or Xcode will not build them.

## Constraints and gotchas

- This project is pinned to Capacitor 5 and Xcode 14.2. Do not require a newer Xcode or iOS API without an availability guard (`#available(iOS 14.0, *)`), and do not upgrade Capacitor.
- Host functions run on the engine's own thread. Return synchronously; do not block the main thread.
- Capacitor runs plugin methods off the main thread already, so Keychain work is fine, but UI work must be dispatched to main.
- Keep the plugin class `public` and marked `@objc(ClassName)`, or Capacitor cannot find it.

## Keep the two platforms in step

Android has a matching implementation (`docs/adding-android-native-functions.md`). The host-bridge JSON shapes and the NOT IMPLEMENTED message wording are checked to be identical across platforms. When you add a host function on one platform, add it on the other too.
