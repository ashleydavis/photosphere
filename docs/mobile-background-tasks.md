# Mobile background tasks and the engine pool

Background work on iOS and Android runs in an **engine pool**. This describes what a slot in that pool is, how many there are, what holds one and for how long, and why running out of them hangs the app rather than slowing it down.

Read this before adding a background task to mobile, and before changing the pool size.

## What a slot is

A slot is a **whole JavaScript engine** with the worker bundle loaded into it. QuickJS on Android, JavaScriptCore on iOS. It is not a thread and it is not cheap: each one holds its own copy of the runtime and its own heap, and the bundle is a few megabytes before any work starts.

That cost is why the pool is small. It is also why the pool size is a real decision rather than a number to raise whenever something blocks.

The size is `POOL_SIZE`, and it is declared in two places that must stay in step:

- `apps/android-frontend/android/app/src/main/java/au/com/codecapers/photosphere/jsengine/EnginePool.java`
- `apps/ios-frontend/ios/App/App/JsEngine/EnginePool.swift`

## Measured cost

Raising the pool from three slots to five, measured on an Android emulator running the `47-auto-import` smoke test, which imports two photos with automatic import switched on:

| | Peak memory | Peak swap |
|---|---|---|
| Three slots | 304 MB | 0.2 MB |
| Five slots | 361 MB | 34 MB |

So roughly **28 MB per additional slot**, and the swap figure says the device is working harder for it. This is the platform where the operating system kills the app for using too much memory, and two of the test emulators were killed for memory during the work that produced these numbers. Measure again if you change the size; do not assume the cost is linear or that there is room.

## What holds a slot, and for how long

Two kinds of task, and the difference matters more than anything else here.

**Short tasks** take a slot, do their work, and hand it straight back. Hashing a file, uploading an asset, reading a database summary, syncing. Most tasks are these. Any number of them can be queued: they simply wait their turn.

**Long-running tasks** hold a slot for as long as they run, which may be the life of the app:

| Task | Held for |
|---|---|
| `asset-server` | The whole time the app is open. Every thumbnail the gallery shows comes through it. |
| `auto-import` | As long as automatic import is switched on. |

## Why running out is a hang, not a slowdown

A task that queues another task and waits for it needs **two** slots at once: its own, and one for the task it is waiting on. If the pool is full of tasks that are all waiting on tasks that cannot start, none of them can finish, and none of them will ever give a slot up.

Automatic import is the deepest chain in the app:

| | |
|---|---|
| Slot 1 | `asset-server`, held for the life of the app |
| Slot 2 | `auto-import`, held while the setting is on |
| Slot 3 | `import-assets`, queued by auto-import, which waits for it |
| Slot 4 | `hash-file` and `upload-asset`, queued by import-assets, which waits for them |

At three slots, `import-assets` took the last one and then waited forever for a `hash-file` that could never start. **This is not hypothetical: it is what the app did**, and it is why the pool is five.

The failure is the dangerous part. Nothing errors. Nothing times out. Nothing appears in a log. From outside, the setting is on, the task is running, and the progress counts sit at zero, which is exactly what a phone with no new photos looks like. It was found by a smoke test that waited for a photo to arrive; a test that waited for the task to *start* would have passed.

## Rules for adding a background task to mobile

1. **Prefer a short task.** Take a slot, finish, give it back.
2. **If it queues another task and waits, count the slots.** Add your chain to the two permanent holders above and check it still fits inside `POOL_SIZE` with one spare.
3. **If it must run for the life of the app, think again.** There are two such tasks and each one permanently reduces what everything else has.
4. **Never test by waiting for a task to start.** Wait for the work to have actually happened. A deadlocked chain starts perfectly.
5. **Raising `POOL_SIZE` is a last resort, and costs memory on the most constrained device.** It also only moves the wall: one more level of nesting and you are back here.

## Where this is enforced

Nothing checks it automatically, which is why it is written down. The places that will remind you are:

- `EnginePool.java` and `EnginePool.swift`, where the constant is, each carrying the reasoning above.
- `packages/mobile-worker/mobile-worker-entry.ts`, where mobile's tasks are registered.
- `packages/node-api/src/lib/auto-import.worker.ts`, which names the chain it needs.

## See also

- [Background tasks](background-tasks.md) - how to add a new task type and wire it up on every platform.
- [Automatic photo backup](automatic-photo-backup.md) - the feature whose chain sets the current pool size.
