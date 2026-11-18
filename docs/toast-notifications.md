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
App core (events.sendShowNotification in photosphere-core)
    │  sends the 'show-notification' event to the page
    ▼
platform-provider-ziggy.tsx
    │  listens for 'show-notification'
    │  dispatches to registered callbacks
    ▼
IPlatformContext.onShowNotification(callback)
    │  useEffect in main.tsx subscribes
    ▼
useToast().addToast(...)
    ▼
ToastContainer (rendered inside Main)
```

For events that originate entirely in the renderer (e.g. a button click) you can skip the event layer and call `addToast` directly from any component.

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

## Sending a notification from the app's core

Call `sendShowNotification` in [events.zig](../packages-zig/photosphere-core/src/lib/events.zig) from any message or task handler in the app's core:

```zig
try events.sendShowNotification(services, io, arena, .{
    .message = "Sync complete",
    .color = "success",                                       // primary | success | warning | danger | neutral
    .duration = 5000,                                         // optional, defaults to 5000
    .folderPath = "/some/dir",                                // optional, adds an "Open Folder" button
    .link = .{ .label = "Read more", .url = "https://..." },  // optional inline anchor in the body
    .action = .{ .label = "What's new", .url = "https://..." }, // optional CTA button (URL form)
});
```

The payload is `IShowNotification` in the app's core and `IShowNotificationData` in [platform-context.tsx](../packages/user-interface/src/context/platform-context.tsx) on the page. The page translates the payload as follows:

- `link` is passed straight through as an inline anchor inside the toast body.
- `action` (URL form) becomes a CTA button that opens the URL via `window.open(..., '_blank', 'noopener')`.
- `folderPath` (when `action` is absent) becomes an "Open Folder" button that opens the folder in the system file manager.

`action` wins over `folderPath` when both are set.

## Sending a notification from a worker

To show a notification when a background task ends, send it from `handleTaskEnd` in [main-process.zig](../packages-zig/photosphere-core/src/lib/main-process.zig), which runs on the main thread when any task ends:

```zig
if (std.mem.eql(u8, end.task_type, "my-task")) {
    try events.sendShowNotification(services, io, arena, .{
        .message = if (end.status == .succeeded) "Task complete" else "Task failed",
        .color = if (end.status == .succeeded) "success" else "danger",
    });
}
```

Register the task as [Tasks](tasks.md) describes.

## Existing notifications

| Source                  | Task / event            | Notification                                          |
|-------------------------|-------------------------|-------------------------------------------------------|
| `handleTaskEnd`         | `import-assets`         | Red on failure                                        |
| `handleTaskEnd`         | `replicate-database`    | Green on success; red on failure                      |
| `checkForNews()` once the page has loaded | `check-for-news` | Oldest unseen item from `news.yaml`; optional inline link and URL CTA |
