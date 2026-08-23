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
| `import-assets` | For the length of one automatic import run, which ends when it has read its sources to the end. The app starts the next one a couple of seconds later. |

## Priority: who gets the next free slot

Every task carries a priority, and there is **one** queue of waiting tasks. The pool always takes from the head. An interactive task joins the head of the queue; a background task joins the end. That is the whole of the mechanism, and it works identically on Android, iOS and the desktop.

Two consequences worth knowing. Background work keeps its arrival order, because it only ever joins the end. Interactive work does not: a second tap goes in front of a first one that is still waiting, so the most recent thing the user asked for is served first.

- **Interactive** means the user is sitting in front of the app waiting for this: opening a database (`load-assets`, `check-database-exists`, `create-database`) and reading the database list (`read-databases-config`, `write-databases-config`).
- **Background** is everything else, and is the default. Automatic import, syncing, and everything they queue.

A task that names no priority runs in the background, so nothing gets in front of the user by accident. A task queued from inside a running task runs at that task's priority unless it names one of its own, which is what stops an import's `hash-file` and `upload-asset` children overtaking a tap. `prefetch-database` is the one task that opts back down: `load-assets` is interactive and queues it, but pulling down every thumbnail of a partial database is background work.

Priority decides the order tasks are dispatched in. It does not interrupt anything: a task the user is waiting on still waits for a running background task to give its slot up, which is why the number of slots an import is allowed to fill matters as much as the ordering does.

The ordering rules live in one place for the desktop pools, `packages/task-queue/src/lib/pending-task-queue.ts`, and are restated in `EnginePool.java` and `EnginePool.swift` because those cannot import it. All three do the same two things: head for interactive, end for background.

## How much of the pool one task may fill

An import queues a `hash-file` task for every file its scan finds, and the scan runs far faster than the hashing. Left alone that fills the pool in seconds and everything else in the app queues behind it. A task that queues work of its own is therefore held to `ITaskContext.maxConcurrentChildTasks` children in flight, queueing the next as each completes.

The number comes from the platform, not the caller: whatever builds the task context fills it in. The mobile worker runtime uses 2, because every engine a task fills is one a tap has to wait for; the Electron worker, the CLI worker, the development server pool and the development frontend use 10. Each declares its own beside the code that builds the context, so nothing has to be passed down through the task that uses it.

## Why running out is a hang, not a slowdown

A task that queues another task and waits for it needs **two** slots at once: its own, and one for the task it is waiting on. If the pool is full of tasks that are all waiting on tasks that cannot start, none of them can finish, and none of them will ever give a slot up.

Automatic import is the deepest chain in the app:

| | |
|---|---|
| Slot 1 | `asset-server`, held for the life of the app |
| Slot 2 | `import-assets`, held for the length of one run |
| Slot 3 | `hash-file` and `upload-asset`, queued by import-assets, which waits for them |

At three slots, `import-assets` took the last one and then waited forever for a `hash-file` that could never start. **This is not hypothetical: it is what the app did**, and it is why the pool is five.

The chain was one deeper when that happened: a separate `auto-import` task sat in a slot of its own for as long as the setting was on, and started `import-assets` in another. That task is gone, and an import run now ends rather than lasting as long as the setting. The pool is still five: nothing has measured what a smaller one does to the chain that remains, and the cost of being wrong is a silent hang.

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
- `packages/node-api/src/lib/import-assets.worker.ts`, which names the chain it needs.

## See also

- [Background tasks](background-tasks.md) - how to add a new task type and wire it up on every platform.
- [Automatic photo backup](automatic-photo-backup.md) - the feature whose chain sets the current pool size.
