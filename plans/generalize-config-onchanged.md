# Plan: Generalize onThemeChanged into IConfig.onChanged

## Context

`IPlatformContext.onThemeChanged` is a one-off subscription mechanism specifically for theme changes. Since the theme is stored as a config key (`'theme'`), this is really just "subscribe to changes on a config key". Generalizing this into `IConfig.onChanged(key, callback)` removes theme-specific concerns from `IPlatformContext`, and allows any future config key to be observed without adding more platform-specific methods.

## Architecture

`IConfig.onChanged<T>(key, callback)` — subscribers register on a key. Notifications fire in two situations:
1. **Local changes**: `config.set('theme', value)` fires listeners immediately in the renderer.
2. **Cross-process changes** (Electron only): the menu bar changes theme in the main process, which sends a `'config-changed'` IPC event; the electron provider calls `config.notifyChanged(key, value)`.

To avoid a double-fire in the IPC echo path (currently the main process re-sends `theme-changed` when the renderer calls `setConfig`), remove the echo from the `setConfig` IPC handler and rely on `set()` firing local listeners instead. Menu-initiated changes still send `'config-changed'` since they originate in the main process.

`createConfig` returns an `IConfigWithNotify` (internal extended type) that includes `notifyChanged`. Only `IConfig` is surfaced through the context. The electron provider retains a typed reference to call `notifyChanged` from a `useEffect`.

## Files to Modify

### 1. `packages/user-interface/src/context/config-context.tsx`
- Import `Unsubscribe` from `./platform-context`.
- Add `onChanged<T>(key: string, callback: (value: T) => void): Unsubscribe` to `IConfig`.
- Add exported `IConfigWithNotify extends IConfig` with `notifyChanged(key: string, value: unknown): void`.
- In `createConfig`:
  - Maintain `const listeners = new Map<string, Set<(value: unknown) => void>>()`.
  - In `set()`, after `await setRaw(...)`, call `listeners.get(key)?.forEach(cb => cb(value as unknown))`.
  - Implement `onChanged`: add typed callback to the map, return delete-from-map unsubscribe.
  - Implement `notifyChanged`: dispatch to all callbacks for the given key.
  - Change return type from `IConfig` to `IConfigWithNotify`.

### 2. `packages/user-interface/src/context/platform-context.tsx`
- Remove `onThemeChanged` from `IPlatformContext`.

### 3. `apps/desktop-frontend/src/lib/platform-provider-electron.tsx`
- Remove `themeCallbacksRef`, its `useEffect`, and the `onThemeChanged` callback.
- Wrap `createConfig(...)` in `useMemo([electronAPI])` and type as `IConfigWithNotify`.
- Add a `useEffect([electronAPI, config])` that calls `electronAPI.onMessage('config-changed', ...)` and dispatches to `config.notifyChanged(key, value)`. Cleanup calls `electronAPI.removeAllListeners('config-changed')`.
- Remove `onThemeChanged` from the `platformContext` object.
- Update import: add `IConfigWithNotify` from `user-interface`.

### 4. `apps/dev-frontend/src/lib/platform-provider-web.tsx`
- Remove `onThemeChanged` no-op callback and its entry from `platformContext`.

### 5. `apps/desktop/src/main.ts`
- In the `setConfig` IPC handler (~line 212): remove the `if (key === 'theme') mainWindow.webContents.send('theme-changed', value)` block — local `set()` now fires listeners in the renderer directly.
- In the three menu click handlers (~lines 563, 575, 587): change `mainWindow.webContents.send('theme-changed', value)` to `mainWindow.webContents.send('config-changed', { key: 'theme', value })`.

### 6. `packages/electron-defs/src/lib/electron-api.ts`
- Add `IConfigChangedMessage { key: string; value: unknown }` interface for the typed IPC payload.

### 7. `packages/user-interface/src/main.tsx`
- Replace `platform.onThemeChanged((theme) => setMode(theme))` with `config.onChanged<'light' | 'dark' | 'system'>('theme', (theme) => setMode(theme))`.
- `config` is already available via `useConfig()` (line 48).

## Tests

Add unit tests in `packages/user-interface/src/test/config-context.test.ts`:
- `onChanged` fires when `set()` is called with the matching key.
- `onChanged` does not fire for a different key.
- Unsubscribe prevents further callbacks.
- `notifyChanged` fires callbacks for the key.

## Verification

1. `bun run compile` from repo root — must pass with no TS errors.
2. `bun run test` — existing tests must pass; new config-context tests must pass.
3. Launch Electron desktop app, open Theme menu — switching between Light/Dark/System must update the UI.
