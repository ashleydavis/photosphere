# Adding native functions on Android

There are two separate ways to add native behaviour. Pick by who needs it.

- The background worker (the embedded JS engine) needs a Node-style function (file, crypto, network): add a **host bridge function**.
- The app UI (the WebView) needs a device feature (pick a file, keychain): add a **Capacitor plugin method**.

They are different systems. Do not mix them up.

All Android native code lives under `apps/android-frontend/android/app/src/main/java/au/com/codecapers/photosphere/`.

## 1. Host bridge function (for the background worker)

The worker runs JavaScript in QuickJS. It calls native code through a global object called `host`, for example `host.fsReadFile(path)`. Calls are synchronous: JS calls in, native returns a value straight back.

You touch four files:

1. `jsengine/HostFunctions.java` — write the actual work as a static method. Use plain Java (`java.io`, etc.), no `android.*`, so it can be unit tested.
2. `jsengine/HostBridge.java` — add a method with the exact name JS will call. It just forwards to your `HostFunctions` method.
3. `jsengine/QuickJsTaskEngine.java` — in `ensureContext(...)`, register the name on the `host` object.
4. `packages/mobile-worker/src/shims/…` — add the function to the shim's TypeScript interface and call it. Then rebuild the bundle (see below).

### The registration line to copy

In `QuickJsTaskEngine.ensureContext`, each function is added like this:

```java
host.setProperty("myThing", (JSCallFunction) args ->
    safeString(() -> hostBridge.myThing((String) args[0])));
```

Always wrap the call in one of these, never call raw. A thrown Java exception cannot cross into QuickJS and will crash the app.

- `safeString(...)` — the function returns a string.
- `safeBoolean(...)` — the function returns true/false.
- `safeVoid(...)` — the function returns nothing.

### Passing data

- Arguments arrive as `Object[] args`. Strings are `String`. Numbers are `Number` (use `((Number) args[0]).intValue()`). For booleans use the `toBoolean(...)` helper so missing values become `false`.
- File contents cross as **base64 strings** in both directions (`base64Encode` / `base64Decode` in `HostFunctions`).
- Structured data crosses as a **JSON string** you build by hand (see how `fsStat` returns `{"size":...,"mtimeMs":...}`).
- A missing file returns `null`.

### Reporting errors

Do not throw. Return the error envelope string `@@HOSTERR@@<code>:<message>` (built by `HostFunctions.hostErrorEnvelope(...)`). The `safe*` wrappers do this for you. The JS side turns it back into a normal error with a Node-style `error.code`.

### The JS side

Each shim declares its own small interface for the host functions it uses and reads `host` at call time. Add your function's signature there and call it through `callHost(() => host.myThing(...))` (in `packages/mobile-worker/src/shims/host-access.ts` and friends).

## 2. Capacitor plugin method (for the app UI)

The UI talks to native features through Capacitor plugins. The main one is `JsEnginePlugin` (`jsengine/JsEnginePlugin.java`), registered under the JS name `"JsEngine"`. File picking lives here as `pickFiles`.

### The method to copy

```java
@PluginMethod
public void myMethod(PluginCall call) {
    String value = call.getString("value");
    if (value == null) {
        call.reject("myMethod requires value.");
        return;
    }
    // ... do the work ...
    call.resolve();               // or call.resolve(resultJsObject)
}
```

Read inputs with `call.getString(...)` / `call.getObject(...)`. Return with `call.resolve(...)`, fail with `call.reject(...)`.

### Anything that opens a screen (like a file picker)

Launching an activity is asynchronous, so use the two-part pattern (see `pickFiles`):

```java
@PluginMethod
public void pickFiles(PluginCall call) {
    Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
    // ...configure intent...
    startActivityForResult(call, intent, "pickFilesResult");
}

@ActivityCallback
private void pickFilesResult(PluginCall call, ActivityResult result) {
    // ...resolve the original call here...
}
```

### The JS side

The plugin's interface is `IJsEnginePlugin` in `packages/mobile-frontend/src/lib/js-engine-plugin.ts`. Add your method there. App code usually wraps it in a plain function in `mobile-platform-tasks.ts` (like `pickMobileFiles`).

### A brand-new plugin

If you add a new plugin class (not just a method), register it in `MainActivity.java` before `super.onCreate`:

```java
registerPlugin(MyPlugin.class);
```

and on the JS side: `export const MyPlugin = registerPlugin<IMyPlugin>("MyPlugin");`. The name in `@CapacitorPlugin(name = "MyPlugin")` and in `registerPlugin("MyPlugin")` must match exactly.

## After changing worker shims: rebuild the bundle

The worker JS is shipped as a prebuilt file. After editing anything in `packages/mobile-worker/src/`, rebuild and copy it:

```
bun run bundle:worker
```

(run from `apps/android-frontend`). This regenerates `apps/android-frontend/android/app/src/main/assets/worker.bundle.js`.

## Keep the two platforms in step

iOS has a matching implementation (`docs/adding-ios-native-functions.md`). The host-bridge JSON shapes and the NOT IMPLEMENTED message wording are checked to be identical across Android and iOS. When you add a host function on one platform, add it on the other too.

## Gotchas

- The QuickJS context runs on one worker thread. Only touch it from that thread. If native work finishes on another thread (network callbacks), hand the result back through the existing event path, don't call the context directly.
- All file paths must go through `PathSandbox.resolveWithin(storageRoot, path)`, which blocks absolute paths and `..`.
- A new plugin **method** on an existing plugin needs no registration. A new plugin **class** does (in `MainActivity`).
