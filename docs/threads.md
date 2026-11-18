# Threads

How the Photosphere App and the Zig CLI use threads. The Photosphere App runs on the threads of [Ziggy](https://github.com/ashleydavis/ziggy): the native app's UI thread, the main thread and the worker threads. [Threads](https://github.com/ashleydavis/ziggy/blob/HEAD/docs/user-guide/threads.md) in Ziggy's user guide describes those threads, what each may touch and the messages between them. This doc covers what Photosphere adds and how it uses them. For how Photosphere writes and queues tasks, see [Tasks](tasks.md).

## Photosphere's state

Photosphere's `MainState` (`packages-zig/photosphere-core/src/lib/main-state.zig`) is the app's state on the main thread: the open databases, whether a sync is running, what automatic import is doing and the timers. `onCreate` makes it and `onDestroy` destroys it after every task has ended. The main thread applies what a task sends back in `onTaskEnd` and `onTaskEvent` (`main-process.zig`). See [Threads and state](https://github.com/ashleydavis/ziggy/blob/HEAD/docs/user-guide/tasks.md#threads-and-state) in Ziggy's guide for the rules this follows.

The caches a task builds (vaults, the hash cache, the S3 client, the last error) are `threadlocal`, so each worker has its own copy.

## The asset server and the MCP server

Photosphere starts threads of its own for its two HTTP servers on loopback. Both use `node-utils-zig`'s `http_server` (`packages-zig/node-utils-zig/src/lib/http-server.zig`): an accepting thread posts each connection to a server thread, which hands it to a connection thread from a pool. The threads talk by Ziggy's `MessageQueue`. Each makes its own allocator and Io.

- **The asset server** serves images, video and asset writes to the page. The main thread opens its socket when the page asks for its query, so the page gets the port at once. It is not a task. Each connection thread keeps its own core and its own cache of database storages. A connection thread that needs the mobile's keychain asks the main thread for it by message.
- **The MCP server** (`mcp-server.zig`, desktop only) passes each tool call to the page as an `mcp-tool-request` event. The main thread passes the page's `mcp-tool-response` back to the connection thread that holds the call.
- **Writes to a database** from different threads (a task and an asset server connection) are kept apart by the database's `.db/write.lock` file, not by a lock in memory.

## The Zig CLI

The CLI has no Ziggy core and no main thread of Ziggy's. Its own thread owns a Ziggy `WorkerPool`, the same pool that runs the Photosphere App's tasks, which `initContext` (`apps/cli-zig/src/lib/init-cmd.zig`) makes with `WorkerPool.create` so the pool has a queue of its own. Its workers are Ziggy's `Worker` and its queues are Ziggy's `MessageQueue`. The pool is the CLI thread's queue backend, so a command queues tasks with a `TaskQueue` and waits in `awaitTask` or `awaitAllTasks`, which reads the workers' messages while it waits.

- The pool's size is the processor count unless `--workers` sets it.
- A task has a timeout (`--timeout`, in milliseconds, given to the pool as `task_timeout_ms`). A task that runs past it is failed with `Task timeout`, and `[Task Queue] Task <id> timed out after <ms>ms` is logged. Its worker is abandoned (left to run, with what it still sends dropped) and replaced by a worker with the same number, because a thread cannot be stopped from outside.
- A worker that cannot be started logs `Worker <n> could not start: <reason>` and is let go. Its task waits for another worker.
- A worker's log lines are written by `apps/cli-zig/src/lib/worker-log.zig`, prefixed with the worker and its task (`[W<n>:<task id>]`). With `--verbose`, a failed task is reported as `Task <id> failed: <error name>: <error message>`.
- When the process ends, the termination callback sends each running task a cancel and waits for every worker's thread to end (`WorkerPool.stopWorkers`).
- Other CLI threads: the signal watcher (`process-signals.zig`) and the spinner and key swallower of the prompts (`apps/cli-zig/src/lib/clack`).

## What Photosphere's threads do while they have no message

[What a thread does while it has no message](https://github.com/ashleydavis/ziggy/blob/HEAD/docs/user-guide/threads.md#what-a-thread-does-while-it-has-no-message) in Ziggy's user guide covers the UI thread, the main thread and the workers. Photosphere's own threads wait like this:

- **An HTTP server's accepting thread** sleeps in `accept` on the listening socket.
- **An HTTP server's server thread** sleeps on its queue until a connection or a message comes. When a connection has sent no request, it waits no longer than until that connection reaches the idle limit, then ends that connection's read so its connection thread is free again.
- **An HTTP connection thread** with no connection sleeps on its queue until it is given one. While it serves a connection it sleeps in a read on the socket. A handler that holds its connection open (the MCP server's event stream) sleeps on the thread's queue with a timeout (`Request.waitForMessage`).
- **The CLI's thread** sleeps in `WorkerPool.waitForMessage` while a command waits on its tasks. It waits on its queue no longer than until the next of its timers or task timeouts is due. When it wakes it handles the message, fails the tasks that are past their timeout and runs the timers that are due.
- **The signal watcher** sleeps in `poll` on a pipe that the signal handler writes to.
- **The spinner** sleeps between frames of its animation.
- **The key swallower** waits for a key with a timeout of 100 ms, so it sees its stop flag within that time.

## Where state is shared

These are the places in Photosphere's code where two threads touch the same memory, outside the message queues:

- Atomic flags: the LAN share sender and receiver's cancel and done flags (`lan-share-network-zig`), the CLI's pending signals, the spinner's stop flag and the `sync` command's stop flag.
- The CLI spinner's mutexes (`apps/cli-zig/src/lib/clack/prompts/spinner.zig`).
