# Toast Notifications

Toast notifications are small, temporary messages displayed in the bottom-right corner of the screen. They auto-dismiss after a configurable duration and can include an optional action button.

## Quick reference

```tsx
const { addToast } = useToast();

addToast({
    message: "Something happened",
    color: "success",                          // primary | success | warning | danger | neutral
    duration: 5000,                            // ms; 0 = never auto-dismiss (default: 5000)
    action: { label: "Open", onClick: fn },    // optional button
    link: { label: "Read more", url: "..." },  // optional inline anchor below the message
});
```

## Architecture

```
Electron main process  (or worker via sendNotification)
    │  mainWindow.webContents.send('show-notification', payload)
    ▼
platform-provider-electron.tsx
    │  electronAPI.onMessage('show-notification', handler)
    │  dispatches to registered callbacks
    ▼
IPlatformContext.onShowNotification(callback)
    │  useEffect in main.tsx subscribes
    ▼
useToast().addToast(...)
    ▼
ToastContainer (rendered inside Main)
```

For events that originate entirely in the renderer (e.g. a button click) you can skip the IPC layer and call `addToast` directly from any component.

## Adding a notification from a React component

Call `useToast()` anywhere inside the component tree:

```tsx
import { useToast } from "user-interface";

function MyComponent() {
    const { addToast } = useToast();

    async function handleAction() {
        try {
            await doWork();
            addToast({ message: "Done!", color: "success" });
        }
        catch (err) {
            addToast({ message: `Failed: ${err.message}`, color: "danger", duration: 8000 });
        }
    }
}
```

No wiring needed — `ToastContextProvider` is already in the tree inside `Main`.

## addToast options

| Field    | Type                                              | Required | Default | Notes                        |
|----------|---------------------------------------------------|----------|---------|------------------------------|
| `message`  | `string`                                          | yes      | —       | Text shown in the toast      |
| `color`    | `'primary' \| 'success' \| 'warning' \| 'danger' \| 'neutral'` | yes      | —       | Controls background colour   |
| `duration` | `number` (ms)                                     | no       | `5000`  | `0` = never auto-dismiss     |
| `action`   | `{ label: string; onClick: () => void }`          | no       | —       | Button shown in the toast    |
| `link`     | `{ label: string; url: string }`                  | no       | (none)  | Inline anchor rendered below the message; opens in a new tab |
| `onDismiss` | `() => void`                                     | no       | —       | Called when the user clicks the close button. Not fired on auto-dismiss timer. Used by news/update toasts to persist their "seen" state only on explicit close. |

## Sending a notification from the main process

Send `show-notification` from any `ipcMain` handler or menu click in [main.ts](../apps/desktop/src/main.ts):

```ts
mainWindow.webContents.send('show-notification', {
    message: 'Sync complete',
    color: 'success',       // primary | success | warning | danger | neutral
    duration: 5000,         // optional, defaults to 5000
    folderPath: '/some/dir',                                // optional, adds an "Open Folder" button
    link: { label: 'Read more', url: 'https://...' },       // optional inline anchor in the body
    action: { label: 'What\'s new', url: 'https://...' }    // optional CTA button (URL form)
});
```

The payload is typed as `IShowNotificationData` in [platform-context.tsx](../packages/user-interface/src/context/platform-context.tsx). The renderer translates the payload as follows:

- `link` is passed straight through as an inline anchor inside the toast body.
- `action` (URL form) becomes a CTA button that opens the URL via `window.open(..., '_blank', 'noopener')`. External URLs are routed through `shell.openExternal` by the existing `setWindowOpenHandler` in [main.ts](../apps/desktop/src/main.ts).
- `folderPath` (when `action` is absent) becomes an "Open Folder" button that opens the folder in the system file manager.

`action` wins over `folderPath` when both are set.

## Sending a notification from a worker

Workers cannot access `mainWindow` directly. Instead, queue a background task that **returns** a result object, then handle it in `onTaskComplete` inside `initWorkers()` in [main.ts](../apps/desktop/src/main.ts):

```ts
// In the task handler (packages/api/src/lib/my-task.worker.ts)
export async function myTaskHandler(data: IMyTaskData, _context: ITaskContext): Promise<IMyTaskResult> {
    // ... do work ...
    return { succeeded: true, folderPath: data.folderPath };
}

// In initWorkers() in main.ts
taskQueue.onTaskComplete<ITask<any>, any>((task, result) => {
    if (task.type === "my-task" && mainWindow) {
        const { succeeded, folderPath } = result.outputs as IMyTaskResult;
        mainWindow.webContents.send('show-notification', {
            message: succeeded ? 'Task complete' : 'Task failed',
            color: succeeded ? 'success' : 'danger',
            folderPath: succeeded ? folderPath : undefined,
        });
    }
});
```

Remember to register the handler in [task-handlers.ts](../packages/api/src/lib/task-handlers.ts).

## Existing notifications

| Source                  | Task / event            | Notification                                          |
|-------------------------|-------------------------|-------------------------------------------------------|
| `onTaskComplete`        | `save-asset`            | Green on success with Open Folder; red on failure     |
| `onTaskComplete`        | `save-assets-batch`     | Green/yellow/red summary with Open Folder on success  |
| `checkForNews()` on startup | `did-finish-load`   | Oldest unseen item from `news.yaml`; optional inline link and URL CTA |
