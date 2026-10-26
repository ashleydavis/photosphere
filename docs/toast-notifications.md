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
Photosphere core, on the main thread or in a task
    │  events.sendShowNotification(sink, io, arena, notification)
    ▼
platform-provider-ziggy.tsx
    │  messages.onEvent('show-notification', handler)
    │  dispatches to registered callbacks
    ▼
IPlatformContext.onShowNotification(callback)
    │  useEffect in main.tsx subscribes
    ▼
useToast().addToast(...)
    ▼
ToastContainer (rendered inside Main)
```

For events that originate entirely in the page (e.g. a button click) you can skip the core and call `addToast` directly from any component.

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

## Sending a notification from the core

Call `sendShowNotification` in [events.zig](../packages-zig/photosphere-core/src/lib/events.zig) from anywhere in the core that has a sink, for example `onTaskEnd` in [main-process.zig](../packages-zig/photosphere-core/src/lib/main-process.zig):

```zig
try events.sendShowNotification(services, io, arena, .{
    .message = "Sync complete",
    .color = "success", // primary | success | warning | danger | neutral
    .duration = 5000, // optional, defaults to 5000
    .folderPath = "/some/dir", // optional, adds an "Open Folder" button
    .link = .{ .label = "Read more", .url = "https://..." }, // optional inline anchor in the body
    .action = .{ .label = "What's new", .url = "https://..." }, // optional CTA button (URL form)
});
```

The payload is `IShowNotification` in `events.zig`, and `IShowNotificationData` in [platform-context.tsx](../packages/user-interface/src/context/platform-context.tsx) on the page. The page translates the payload as follows:

- `link` is passed straight through as an inline anchor inside the toast body.
- `action` (URL form) becomes a CTA button that opens the URL via `window.open(..., '_blank', 'noopener')`.
- `folderPath` (when `action` is absent) becomes an "Open Folder" button that opens the folder in the system file manager.

`action` wins over `folderPath` when both are set.

## Sending a notification from a task

A task never reaches the main thread's state. Pass the task's services as the sink: `sendEvent` then sends the event as a task event of type `APP_EVENT_TYPE`, and the main thread sends it on to the page (see `events.zig`). A task can also return its result and leave the main thread to decide, in `onTaskEnd` in `main-process.zig`, as the import and replication notifications do.

## Existing notifications

| Source                  | Task / event            | Notification                                          |
|-------------------------|-------------------------|-------------------------------------------------------|
| `onTaskEnd`             | `import-assets`         | Red on failure                                        |
| `onTaskEnd`             | `replicate-database`    | Green on success; red on failure                      |
| `checkForNews()` once the page has loaded | `check-for-news` | Oldest unseen item from `news.yaml`; optional inline link and URL CTA |
