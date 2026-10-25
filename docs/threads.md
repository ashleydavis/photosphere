# Threads

How the Photosphere App and the Zig CLI use threads. The Photosphere App runs on the threads of [Ziggy](https://github.com/ashleydavis/ziggy): the native app's UI thread, the main thread and the worker threads. [Threads](https://github.com/ashleydavis/ziggy/blob/HEAD/docs/user-guide/threads.md) in Ziggy's user guide describes those threads, what each may touch and the messages between them. This doc covers what Photosphere adds and how it uses them. For how to write and queue a task, see [Tasks](tasks.md).

Photosphere keeps Ziggy's rule: threads share no state. The only thing two threads both touch is a message queue that carries copies of JSON text (see `CLAUDE.md`).

## Photosphere's state on the main thread

Photosphere's `MainState` (`packages-zig/photosphere-core/src/lib/main-state.zig`) is the app's state: the open databases, whether a sync is running, what automatic import is doing and the timers. `onCreate` makes it on the main thread and `onDestroy` destroys it there after every task has ended. Only the message handlers, menu functions and timers read it. They all run on the main thread.

A task never reaches `MainState`. It gets what it needs in its data. The main thread applies what the task sends back in `onTaskEnd` and `onTaskEvent` (`main-process.zig`).

## How Photosphere uses the main thread and the workers

- **Messages that wait on something slow** (the keychain, a file, a dialog, the phone) return `.task` from their handler, so the work runs on a worker and the main thread goes on to the next message.
- **Work the app starts itself** (the periodic and debounced sync, automatic import, the background passes, the update and news checks) is queued from the main thread with `services.addTask` and cancelled with `services.cancelTasks`. The timers that start it are the main thread's.
- **Child tasks.** `import-assets` makes a `TaskQueue` on its worker, queues `hash-file` and `upload-asset` children through it and waits for them.
- **Caches a task builds** (vaults, the hash cache, the S3 client, the last error) are `threadlocal`, so each worker has its own copy.

## The asset server and the MCP server

Photosphere starts threads of its own for its two HTTP servers on loopback. Both use `node-utils-zig`'s `http_server` (`packages-zig/node-utils-zig/src/lib/http-server.zig`): an accepting thread posts each connection to a server thread, which hands it to a connection thread from a pool. The threads talk by Ziggy's `MessageQueue`. Each makes its own allocator and Io.

- **The asset server** serves images, video and asset writes to the page. The main thread opens its socket when the page asks for its query, so the page gets the port at once. It is not a task. Each connection thread keeps its own core and its own cache of database storages. A connection thread that needs the phone's keychain asks the main thread for it by message.
- **The MCP server** (`mcp-server.zig`, desktop only) passes each tool call to the page as an `mcp-tool-request` event. The main thread passes the page's `mcp-tool-response` back to the connection thread that holds the call.
- **Writes to a database** from different threads (a task and an asset server connection) are kept apart by the database's `.db/write.lock` file, not by a lock in memory.

## The Zig CLI

The CLI has no Ziggy core and no main thread of Ziggy's. Its own thread owns `WorkerPoolBun` (`apps/cli-zig/src/lib/worker-pool.zig`), whose workers are Ziggy's `Worker` and whose queues are Ziggy's `MessageQueue`. That pool is the CLI thread's queue backend, so a command queues tasks with a `TaskQueue` and waits in `awaitTask` or `awaitAllTasks`, which reads the workers' messages while it waits.

- The pool's size is the processor count unless `--workers` sets it.
- A task has a timeout (`--timeout`). A task that runs past it is failed. Its worker is detached (left to run, with what it still sends ignored) and replaced, because a thread cannot be stopped from outside.
- A worker that cannot be started is a crashed worker: its task fails and it is replaced.
- Other CLI threads: the signal watcher (`process-signals.zig`) and the spinner and key swallower of the prompts (`apps/cli-zig/src/lib/clack`).

## Where state is shared

These are the places in Photosphere's code where two threads touch the same memory, outside the message queues:

- Atomic flags: the LAN share sender and receiver's cancel and done flags (`lan-share-network-zig`), the CLI's pending signals, the spinner's stop flag and the `sync` command's stop flag.
- The CLI spinner's mutexes (`apps/cli-zig/src/lib/clack/prompts/spinner.zig`).
- The mutex that keeps lines written to standard output whole (`utils-zig/src/lib/console.zig`).

## Key files

| File | What it holds |
|---|---|
| `packages-zig/photosphere-core/src/lib/main-state.zig` | Photosphere's state on the main thread and the timers that queue its work. |
| `packages-zig/photosphere-core/src/lib/main-process.zig` | `onTaskEnd`, `onTaskEvent` and the main command. |
| `packages-zig/node-utils-zig/src/lib/http-server.zig` | The threads of the asset server and the MCP server. |
| `packages-zig/node-api-zig/src/lib/asset-server.zig` | The asset server. |
| `packages-zig/photosphere-core/src/lib/mcp-server.zig` | The MCP server. |
| `apps/cli-zig/src/lib/worker-pool.zig` | The CLI's worker pool. |
