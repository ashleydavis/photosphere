# Part 1: Picker Infrastructure

Adds two IPC capabilities that the subsequent task-collapse plans depend on: a new `pick-file` handler that exposes the native save dialog to the renderer, and an `IPickFolderOptions` argument on the existing `pick-folder` handler for controlling title, default path, persist target, and the "New Folder" button. No existing handlers are removed and no behaviour changes.

## Step 1 -- Add `pick-file` IPC

### 1a. Main process handler

File: [apps/desktop/src/main.ts](apps/desktop/src/main.ts)

Add next to the existing `pick-folder` handler:

```ts
ipcMain.handle('pick-file', logExceptions(async (_event, defaultFilename: string) => {
    const config = await loadDesktopConfig();
    const defaultPath = config.lastDownloadFolder
        ? join(config.lastDownloadFolder, defaultFilename)
        : defaultFilename;
    const result = await dialog.showSaveDialog(mainWindow!, { defaultPath });
    if (result.canceled || !result.filePath) {
        return undefined;
    }
    await updateLastDownloadFolder(dirname(result.filePath));
    return result.filePath;
}, 'Error picking save location'));
```

`updateLastDownloadFolder` moves from inside `save-asset` into the picker -- it belongs here.

### 1b. Preload, electron-defs, platform context

- [apps/desktop/src/preload.ts](apps/desktop/src/preload.ts): `pickFile: (defaultFilename) => ipcRenderer.invoke('pick-file', defaultFilename)`
- [packages/electron-defs/src/lib/electron-api.ts](packages/electron-defs/src/lib/electron-api.ts): add `pickFile: (defaultFilename: string) => Promise<string | undefined>` to `IElectronAPI`
- [packages/user-interface/src/context/platform-context.tsx](packages/user-interface/src/context/platform-context.tsx): add `pickFile: (defaultFilename: string) => Promise<string | undefined>`
- [apps/desktop-frontend/src/lib/platform-provider-electron.tsx](apps/desktop-frontend/src/lib/platform-provider-electron.tsx): wrap `electronAPI.pickFile`
- [apps/dev-frontend/src/lib/platform-provider-web.tsx](apps/dev-frontend/src/lib/platform-provider-web.tsx): stub returning `undefined`

## Step 2 -- Extend `pickFolder` with options

Define `IPickFolderOptions` in [packages/user-interface/src/context/platform-context.tsx](packages/user-interface/src/context/platform-context.tsx) -- it belongs at the platform-abstraction layer, not the Electron layer:

```ts
// Options for the native folder picker dialog.
export interface IPickFolderOptions {
    // Window title shown in the native dialog.
    title?: string;

    // Config key to read the default path from and persist the chosen path back to. The Electron implementation maps this to a key in IDesktopConfig ('lastFolder' is the existing default).
    folderKey?: string;

    // Whether to show the "New Folder" button.
    createDirectory?: boolean;
}
```

Update `IPlatformContext.pickFolder` to accept `options?: IPickFolderOptions`. Calling with no args keeps existing behaviour.

Wire through:
- [packages/electron-defs/src/lib/electron-api.ts](packages/electron-defs/src/lib/electron-api.ts): import `IPickFolderOptions` from `user-interface` and update `IElectronAPI.pickFolder` to accept it.
- [apps/desktop/src/main.ts](apps/desktop/src/main.ts): update `pick-folder` handler to read `folderKey`/`createDirectory` from the options arg.
- [apps/desktop/src/preload.ts](apps/desktop/src/preload.ts): forward `options` to `ipcRenderer.invoke`.
- [apps/desktop-frontend/src/lib/platform-provider-electron.tsx](apps/desktop-frontend/src/lib/platform-provider-electron.tsx): forward `options`.
- [apps/dev-frontend/src/lib/platform-provider-web.tsx](apps/dev-frontend/src/lib/platform-provider-web.tsx): ignore options, return `undefined` as before.

## Unit Tests

- Test that `pick-file` calls `dialog.showSaveDialog` with the correct `defaultPath` derived from `lastDownloadFolder` and updates the config on confirm.
- Test that extended `pickFolder` reads the default path from and persists the chosen path to the config key specified by `folderKey`.

## Verify

1. `bun run compile` passes.
2. `bun run test` passes.
3. `grep 'pick-file' apps/desktop/src/main.ts` finds the new handler.
4. All existing smoke tests pass (no behaviour change yet).
