# Start tasks by a function call, never by a handler's return value

## Overview

A message handler in Ziggy can return `Response(T)` holding `.task = .{ .task_type, .data }`, or `MessageResult` holding `.task` and Ziggy then queues the task under the source `"request"` and sends the task's end as the message response (`queueResponseTask` and `next_request_task` in `packages/ziggy/core/src/lib/core.zig`, `reply_id_json` and `emitReply` in `packages/ziggy/core/src/lib/worker-pool.zig`). This plan removes both `.task` variants and every code path that queues a task from what a handler returns and converts every user in Ziggy and in Photosphere.

A message whose response comes from a task now uses the reply mechanism that already exists: the handler takes `reply: ziggy.core.Reply(Result)`, starts its task with `services.addTask(...)`, keeps the reply on the main thread keyed by the task's id and returns `.later`. The app's `on_task_end` finds the reply for the task that ended and sends the response through it. The reply posts a `later-reply` message to the main thread's queue and `LaterReplies.deliver` in `core.zig` sends it to the frontend, as it does for every `.later` response today.

The one addition to Ziggy is `Reply(T).sendTaskEnd`, which sends the response from a `ziggy.types.TaskEnd` and the export `ziggy.core.ReplyTarget`, so an app keeps replies of every `Result` type in one map.

Repositories (siblings on disk):

- Ziggy: this repository. Run every command from its root.
- Photosphere: `../photosphere` from Ziggy's root. Run every Photosphere command from its root.
- The examples `../ziggy-example-vite` and `../ziggy-example-rsbuild` hold no `.task` result, `MessageResult` or `Reply` (checked with grep over their Zig source), so they need no change.

Every Zig, bun and build command the agent runs goes through `mise exec --` (both repositories have a `mise.toml`).

## Issues

## Steps

### 1. Ziggy: add `Reply(T).sendTaskEnd` and export `ReplyTarget`

- Check `$(git rev-parse --git-common-dir)/hooks/pre-commit` links to `.githooks/pre-commit`. If it does not, run `mise exec -- bun run install-hooks`.
- In `packages/ziggy/core/src/lib/handlers.zig`, add to the struct `Reply(T)` returns:
  - `pub fn sendTaskEnd(self: @This(), io: std.Io, allocator: std.mem.Allocator, end: *const types.TaskEnd) !void`.
  - What it sends, through `postLaterReply` with an arena on `allocator` as `send` and `fail` do: when `end.status == .succeeded`, the data `json.Raw{ .text = end.result_json orelse "null" }`; when `.cancelled`, the error text `"Cancelled"`; when `.failed`, the error text `end.error_message orelse "Failed"`. These are the texts `emitReply` in `worker-pool.zig` gives today, so the frontend sees the same reply.
  - Its comment says why it exists: a task's end carries the text of its error, which the worker already described with the app's `describe_error` and `fail` takes a Zig error, so the text cannot be passed through `fail`. It ignores `T`: the task's result is the response, as it was before.
- In `packages/ziggy/core/src/lib/core.zig`, add `pub const ReplyTarget = handlers_lib.ReplyTarget;` beside `pub const Reply`, with a comment: where a reply sends its response, which an app keeps for replies of any type in one collection.
- Unit tests in `packages/ziggy/core/src/test/app.test.zig`, each starting a core with `reply_app`, sending the `later` message (as the existing later tests do) and calling `firstLaterReply(&native_app).sendTaskEnd(...)` with a `ziggy.types.TaskEnd` built in the test, then `native_app.handled(...)` and `expectLastMessage`:
  - succeeded with `result_json = "{\"text\":\"done\",\"times\":2}"` gives `{"id":<id>,"ok":true,"data":{"text":"done","times":2}}`.
  - succeeded with `result_json = null` gives `{"id":<id>,"ok":true,"data":null}`.
  - failed with `error_message = "the disk is full"` gives `{"id":<id>,"ok":false,"error":"the disk is full"}`.
  - failed with `error_message = null` gives `{"id":<id>,"ok":false,"error":"Failed"}`.
  - cancelled gives `{"id":<id>,"ok":false,"error":"Cancelled"}`.
  - a second `sendTaskEnd` on the same reply gives the `core-error` event naming `MessageAlreadyAnswered`.
- Compile and pass: `mise exec -- bun run test:zig`.

### 2. Ziggy: move the core tests that only use the task-reply messages as a way in

These tests use `quick-request`, `fail-request`, `pick-open-request` or `pick-save-request` (the `respondedByTask` handlers of `packages/ziggy/core/src/test/test-app.zig`) to reach some other behaviour. Each is rewritten to queue the same task with the `add-task` system message (`{"kind":"system","name":"add-task","data":{"taskId":"...","taskType":"...","source":"...","data":...}}`, as `dispatcher.test.zig` already does for `"after"`) and to assert the same values in the `task-completed` event instead of the message response. Each keeps what it asserts about behaviour.

- `dispatcher.test.zig`, "a native dialog is shown through the native app's callback with the title and kind": queue `pick-open` with data `"Choose files"` and `pick-save` with data `"photo.jpg"`, then expect `"outputs":["kind0","Choose files","-"]` and `"outputs":["kind1","-","photo.jpg"]`.
- `dispatcher.test.zig`, "a dialog with no callback from the native app is an error reply naming what is missing": queue `pick-open` with no data and expect `"status":"failed","error":{"message":"NativeCallMissing"}`. Rename it "a dialog with no callback from the native app fails the task naming what is missing".
- `dispatcher.test.zig`, "an app's error describer gives the text of a failed request task's error reply": queue `fail` and expect the `task-completed` event's `"errorMessage"` to be the text `describeTaskError` gives, escaped as the event writes it. Rename it "an app's error describer gives the text of a failed task's error".
- `remote-control.test.zig`, the two tests that send `pick-open-request` (ids 21, 22 and 31): queue `pick-open` tasks with data `"Title"` instead and expect `"outputs":["/picked/one.txt","/picked/two.txt"]`, then `"outputs":["kind0","Title","-"]`, then `"outputs":["/second.txt"]`.
- Compile and pass: `mise exec -- bun run test:zig`.

### 3. Ziggy: the test app starts its pick tasks by a call and replies from `on_task_end`

All in `apps/ziggy-test-app/backend/src/lib/handlers.zig` and `apps/ziggy-test-app/backend/src/app.zig`.

- Add the main thread's record of waiting replies:
  - `const PendingReplies = struct { thread_allocator: ziggy.utils.thread_allocator.ThreadAllocator, by_task: std.StringHashMapUnmanaged(ziggy.core.ReplyTarget) }` with `init` and one `threadlocal var pending_replies: PendingReplies = .init;`. Comment above it, as `rules/general.md` requires for a global: a handler and `on_task_end` are given only the standard arguments, so a reply kept from one to the other has to live where both reach it; Ziggy's Tasks guide ("Threads and state") says the main thread's state is a top-level variable; it is `threadlocal` because each core the tests start has its own main thread. Keys are owned copies of the task ids, allocated with `pending_replies.thread_allocator`.
- Add `const TaskForReply = struct { task_type: []const u8, data_json: []const u8 };` (an options struct, because both are strings).
- Add `fn replyByTask(comptime Result: type, services: HandlerServices, io: std.Io, allocator: std.mem.Allocator, reply: ziggy.core.Reply(Result), task: TaskForReply) !ziggy.core.Response(Result)`:
  - task id: `std.fmt.allocPrint(allocator, "{s}-reply-{d}", .{ task.task_type, reply.target.serial })` (a serial is unique within a core).
  - put the owned id and `reply.target` in `pending_replies.by_task`, with an `errdefer` that removes and frees it.
  - `try services.addTask(io, allocator, task_id, task.task_type, PICK_TASK_SOURCE, task.data_json, .interactive)`, with `pub const PICK_TASK_SOURCE = "pickers";`.
  - return `.later`.
- Convert `pickFolderMessageHandler`, `pickFilesMessageHandler` and `pickFileMessageHandler`: each takes a sixth parameter `reply: ziggy.core.Reply(<its Result>)` and returns `try replyByTask(<Result>, services, io, allocator, reply, .{ .task_type = "pick-...", .data_json = <the same JSON it passes today> })`. Their comments say the response is sent from `onTaskEnd` when the task ends.
- Add `fn sendPendingReply(io: std.Io, allocator: std.mem.Allocator, end: *const ziggy.types.TaskEnd) !void`: `fetchRemove(end.task_id)` from `pending_replies.by_task`; when found, free the key and call `(ziggy.core.Reply(void){ .target = target }).sendTaskEnd(io, allocator, end)`; when not found, do nothing (most tasks answer no message).
- `onTaskEnd` calls `sendPendingReply` first and panics with the error's name if it fails, as `sendObserved` does, then sends its `task-ended` event as now.
- Add `pub fn onDestroy(services, timers, io, allocator, phase: ziggy.core.DestroyPhase) void`: at `.after_tasks_stopped` it frees every key, deinits the map and deinits `pending_replies.thread_allocator` (whose report of a leak fails a test) and sets `pending_replies = .init`. Register it in `app.zig` as `.on_destroy = handlers.onDestroy` and change the comment above `app` to say the pickers wait on a native dialog, so each starts a task of the same name and replies when it ends.
- Unit tests in `apps/ziggy-test-app/backend/src/test/handlers.test.zig` (the pick tests that exist stay as they are and must pass unchanged, since the frontend sees the same replies):
  - "a pick task cancelled before it starts gives its message the error reply Cancelled": start with `native_app.config(1, 2)`, add `hello-long` with `{"durationMs":60000,"stepMs":10}` under source `busy`, wait for `long task step 1`, send `pick-folder` with id 8, send `{"kind":"system","name":"cancel-tasks","data":"pickers"}`, expect `{"id":8,"ok":false,"error":"Cancelled"}`.
  - "a pick message sent with send gets no reply and its task still runs": send `{"kind":"app","name":"pick-folder"}` with no id, expect a `task-completed` event with `"type":"pick-folder","status":"succeeded"` and count zero messages containing `"ok":`.
  - "a reply still waiting when the core stops is reported and freed": one worker busy with `hello-long` as above, send `pick-folder` with id 9, stop the core, expect the `core-error` event `MessageNotAnswered: pick-folder`. The thread allocator's leak report fails this test when `onDestroy` leaves an entry.
  - The pick handlers' `task-completed` event now reaches the frontend: "the observers the test app gives the core ..." keeps its counts, because it counts by task id.
- Compile and pass: `mise exec -- bun run compile:zig`, `mise exec -- bun run test:zig`, `mise exec -- bun run compile`, `mise exec -- bun run test`.
- Smoke tests: `mise exec -- bun run test:smoke` (covers `10-pickers` and `desktop-only/25-close-with-dialog-open`, which drive the pick messages end to end).

### 4. Photosphere: every handler starts its task by a call and replies from `onTaskEnd`

All paths are under `../photosphere`. Photosphere builds against the local Ziggy with Zig's `--fork=../ziggy` (it matches the `ziggy` dependency in `build.zig.zon`; `mise exec -- zig build --fork=../ziggy -l` prints "info: fork ../ziggy matched 1 ziggy packages").

- `packages-zig/photosphere-core/src/lib/main-state.zig`:
  - Add `pub const MESSAGE_TASK_SOURCE = "request";` beside the other source constants, with a comment: the source of the tasks that answer the page's messages, so `cancelTasks("request")` cancels every one still running, as it did before.
  - Add `pub const TaskForReply = struct { task_type: []const u8, data_json: []const u8 };` (options struct: two strings).
  - Add to `MainState` the field `message_replies: std.StringHashMapUnmanaged(ziggy.core.ReplyTarget)`, commented: the reply of each message a task answers, by the task's id, with keys owned by the state. Initialise it to `.empty` in `create`. In `destroy`, free every key and deinit the map with the state's allocator.
  - Add `pub fn replyByTask(self: *MainState, comptime Result: type, services: HandlerServices, io: std.Io, allocator: std.mem.Allocator, reply: ziggy.core.Reply(Result), task: TaskForReply) !ziggy.core.Response(Result)`: task id from `self.uuid_generator.uuidGenerator().generate(allocator, io)`; owned copy with `stateAllocator()` put in `message_replies` with an `errdefer` that removes and frees it; `try services.addTask(io, allocator, task_id, task.task_type, MESSAGE_TASK_SOURCE, task.data_json, .interactive)`; return `.later`.
  - Add `pub fn sendTaskReply(self: *MainState, io: std.Io, allocator: std.mem.Allocator, end: *const ziggy.types.TaskEnd) !void`: `fetchRemove(end.task_id)`; when found, free the key with `stateAllocator()` and call `(ziggy.core.Reply(void){ .target = target }).sendTaskEnd(io, allocator, end)`; otherwise do nothing.
- `packages-zig/photosphere-core/src/lib/main-process.zig`, `onTaskEnd`: before `handleTaskEnd`, call `main_state.current().sendTaskReply(io, allocator, &end)` and log a failure with `log.exception("Error sending the reply of a task", err)`, so the reply is sent even when `handleTaskEnd` fails. The reply reaches the page after `handleTaskEnd`'s state changes, because it is posted to the main thread's queue.
- Convert every handler that returns `.task` (find them with `grep -rn '\.task = \.{' packages-zig/photosphere-core/src/lib`): in `vault.zig`, `databases.zig`, `recents.zig`, `pickers.zig`, `saving-assets.zig`, `config-and-state.zig`, `mobile-requests.zig`, `share-import.zig`, `tools.zig`, `update-and-news.zig`, `logging.zig` and `main-process.zig`. Each takes a sixth parameter `reply: ziggy.core.Reply(<its Result>)`, keeps its return type `!ziggy.core.Response(<Result>)` and returns `try main_state.current().replyByTask(<Result>, services, io, allocator, reply, .{ .task_type = <the same task type>, .data_json = <the same data> })`. Drop the `_ = services;` and `_ = io;` lines that become wrong. Import `main-state.zig` where a file does not. `apps/photosphere/core/src/app.zig` registers the same names and needs no change to its tables.
- `logging.zig`: move the data of the `get-log-details` task into `pub fn logDetailsTaskData(log: ILog, allocator: std.mem.Allocator) ![]const u8` (the JSON `getLogDetailsMessageHandler` builds today from `log.logFilePath()`), which the handler calls. In `src/test/logging.test.zig`, "get-log-details with the console log replies with a null path and the placeholder header" calls `logging.logDetailsTaskData(utils.mute_log.MuteLog.init(), arena)` instead of reading `response.task` and keeps its assertions (`"{}"` and the `queueTaskExpecting` line).
- Unit tests in `packages-zig/photosphere-core/src/test/main-state.test.zig`:
  - "a message answered by a task gets the task's result and the page is told the task ended": `requestOk("get-state", "\"gallerySort\"")` gives `null`, then a `task-completed` event with `"type":"get-state","status":"succeeded"` arrives.
  - "the end of a task no message waits on sends no reply": count messages containing `"ok":`, call `support.endTask` with a `TaskEnd` whose id is `"not-a-reply"`, count again and expect the same.
  - "a reply waiting when the app stops is freed": `startWithTasks` with an extra task type `wait-until-cancelled` whose handler calls `services.waitUntilCancelled(io, allocator, timers)`; on the main thread (`onState`, with the address of `app.native_app.queue` in the context as `test-support.zig` already passes function addresses) call `state.replyByTask(void, ..., .{ .target = .{ .queue = <that queue>, .describe_error = null, .serial = 999 } }, .{ .task_type = "wait-until-cancelled", .data_json = "null" })` and return `state.message_replies.count()`, expecting 1; then `app.stop()`. The state allocator's leak report fails the test when `destroy` leaves the entry.
  - The tests that send converted messages (`config-and-state.test.zig`, `saving-assets.test.zig`, `vault.test.zig`, `pickers.test.zig`, `databases.test.zig`, `recents.test.zig`, `mobile-requests.test.zig`, `share-import.test.zig`, `tools.test.zig`, `update-and-news.test.zig`, `logging.test.zig`, `main-process.test.zig`) stay as they are and must pass: the reply text is the same. The failed-task path is covered by "get-log-details is an error reply when the log file cannot be read", which expects the described error text. A count assertion that now also matches the message task's new `task-completed` event is fixed by matching the exact event it is about, never by changing the count.
- Compile and pass Photosphere's Zig unit tests against the local Ziggy: from `../photosphere`, `mise exec -- zig build test --fork=../ziggy --summary all --test-timeout 20m` (the command `bun run test:zig` runs, with the fork added).
- Smoke tests against the local Ziggy, from `../photosphere`:
  1. `env -C apps/photosphere mise exec -- bun run bundle:ui --out-dir "$(pwd)/tmp/local-ziggy/page"`
  2. `mise exec -- zig build photosphere-linux --fork=../ziggy -Dcpu=baseline -Doptimize=ReleaseSafe -Dstrip=false -Dui-directory=tmp/local-ziggy/page --prefix "$(pwd)/tmp/local-ziggy/linux"`
  3. `mise exec -- zig build --fork=../ziggy -p "$(pwd)/tmp/local-ziggy/psi"`
  4. `PHOTOSPHERE_SMOKE_BUILD="$(pwd)/tmp/local-ziggy/linux" PHOTOSPHERE_SMOKE_PSI="$(pwd)/tmp/local-ziggy/psi/bin/psi" mise exec -- bun run test:ziggy`

  `apps/photosphere-smoke-tests/lib/linux.sh` uses the build `PHOTOSPHERE_SMOKE_BUILD` names instead of building and `run.sh` uses the psi `PHOTOSPHERE_SMOKE_PSI` names. These are the steps `sync-linux.sh` runs, with `--fork=../ziggy` added. `tmp/` is in Photosphere's `.gitignore`.

### 5. Docs

- Ziggy `docs/user-guide/messages.md`:
  - "What a handler returns": `Response(Result)` is `.now` or `.later`. In "Taking the message unparsed", remove the `.task` bullet, leaving `.response` and `.none` (a handler that takes `ziggy.core.Message` takes no reply, as `wrapNamed` enforces).
  - "Sending the response later": its example is a handler that starts a task with `services.addTask` and keeps its reply and the app's `on_task_end` sends the response with `reply.sendTaskEnd(io, allocator, &end)`. Say what `sendTaskEnd` sends for a task that succeeded, failed and was cancelled. Remove the sentence that a handler with a reply may return `.task`.
  - Replace "A message whose response is a task's result" with "A message whose response comes from a task", which says the handler starts the task with a call and links to the Tasks guide's section of the same name.
- Ziggy `docs/user-guide/tasks.md`:
  - Replace "A message whose response is a task's result" with "A message whose response comes from a task": the handler takes a reply, starts the task with `services.addTask(...)`, keeps the reply on the main thread keyed by the task's id, returns `.later`; `on_task_end` finds the reply for the task that ended and calls `sendTaskEnd`. Show the test app's `pickFolderMessageHandler`, `replyByTask` and the reply part of `onTaskEnd`. Say the task is an ordinary task: the app chooses its source and its id, the frontend gets its `task-completed` event, a message sent with `send` has no id so its task runs and it gets no response (a failure gives a `core-error` event, as any reply does) and a reply still waiting when the backend stops is reported as `MessageNotAnswered`.
  - "Threads and state": the input of a task is the data in `window.ziggy.addTask` or in `services.addTask`; rewrite the `greeting_count` example to start `write-greeting` with `services.addTask` and keep the reply.
- Ziggy `docs/user-guide/native-calls.md`: the link in the opening paragraph points at the renamed Tasks section.
- Ziggy `docs/user-guide/app-declaration.md`: the `on_task_end` row says it is also where a handler's kept reply is sent when its task ends.
- Ziggy `docs/development/architecture.md`, the message handlers bullet: `Response` is `.now` or `.later` and a task answers a message only through a reply the app sends from `on_task_end`.
- Ziggy `docs/upgrade-notes.md`: add `## v0.0.24` above `## v0.0.23` (when it is absent) with one bullet: `Response`'s and `MessageResult`'s `.task` are gone; a handler that returned `.task` takes `reply: ziggy.core.Reply(Result)`, starts the task with `services.addTask`, keeps the reply by the task's id, returns `.later` and the app's `on_task_end` calls `reply.sendTaskEnd(io, allocator, &end)`; the source `"request"` is gone (the app picks one); the task sends a `task-completed` event; see the Tasks guide's "A message whose response comes from a task".
- `apps/ziggy-template/.claude/commands/ziggy/add-message.md` (line about returning `.task`) and `apps/ziggy-template/.claude/commands/ziggy/add-task.md` (step 5): a message answered by a task has its handler start the task with `services.addTask`, keep its reply and return `.later`, with `on_task_end` sending the response, following the Tasks guide's "A message whose response comes from a task".
- Photosphere `docs/tasks.md`, "Messages answered by a task": the handler calls `main_state.current().replyByTask(...)`, which starts the task under the source `"request"` and keeps the reply in the main state and `onTaskEnd` sends it with `sendTaskReply`. Point the link at `https://github.com/ashleydavis/ziggy/blob/HEAD/docs/user-guide/tasks.md#a-message-whose-response-comes-from-a-task`.
- Photosphere `docs/photosphere-on-ziggy.md`, the Handlers paragraph: replace "That handler returns `.task`" with the same description.
- Photosphere `apps/photosphere/core/src/app.zig`, the comment above `app`: a message whose work waits on something slow starts a task and is answered when it ends.

### 6. Clean up

Removes the `.task` variants, every code path that queues a task from a return value and the tests whose subject is gone.

- `packages/ziggy/core/src/lib/handlers.zig`: remove `task: ResponseTask` from `MessageResult` and `Response(T)`, the type `ResponseTask`, the `.task` branch of `responseResult` and `.task` from the comments of `Response`, `MessageResult`, `wrapNamed` and `responseResult`.
- `packages/ziggy/core/src/lib/core.zig`: remove `pub const ResponseTask`, the `.task` branch of `runAppMessage` (with its `MessageHasNoId`), `queueResponseTask`, `next_request_task` (its `var` and the parameter of `handleFrontendMessage` and `runAppMessage`) and the `pool` parameter of `runAppMessage` (its only use is `queueResponseTask`). Update the comment of `Response`'s export ("comes from a task or later" becomes "later").
- `packages/ziggy/core/src/lib/worker-pool.zig`: remove `PoolTask.reply_id_json`, the `reply_id_json` parameter of `addTask` and `addTaskWithParent`, its free in `destroyTask`, the reply branch of `finish` (it always calls `emitTaskCompleted`) and `emitReply`. Update every caller: `core.zig` `addTaskLater`, `system-messages/tasks.zig`, the two `addTaskWithParent` calls in `worker-pool.zig` and every `fixture.pool.addTask` in `src/test/worker-pool.test.zig`.
- `packages/ziggy/core/src/test/test-app.zig`: remove `respondedByTask`, the messages `quick-request`, `fail-request`, `pick-open-request` and `pick-save-request` and their mention in the comment above `app`.
- Delete these tests, whose subject is gone:
  - `dispatcher.test.zig`: "respondWithTask answers the message with the task's result, without blocking the dispatcher", "a message answered by a task that fails gets an error response", "a message with no id whose response is to be a task's result is refused and queues nothing".
  - `app.test.zig`: "a handler that returns Response .task is answered with the task's result", with `taskHandler` and the `.task` message of `reply_app`.
  - `app.test.zig`: from "a handler that takes ziggy.core.Message gets the message unparsed, and can answer with a task" (its name in the code), remove the `quick-request` lines and rename it "a handler that takes ziggy.core.Message gets the message unparsed".
  - `worker-pool.test.zig`: "a task that replies to a message ends as that message's reply".
- Then run everything in Verify.

## Unit Tests

- Ziggy core (`app.test.zig`): `sendTaskEnd` for succeeded with a result, succeeded with none, failed with text, failed with none, cancelled, then a second send (step 1).
- Ziggy core: the dialog, `NativeCallMissing`, describe-error and remote-control pick tests, moved to `add-task` and the `task-completed` event with the same values (step 2).
- Ziggy test app (`handlers.test.zig`): the existing pick tests unchanged; a cancelled pick task gives `Cancelled`; a pick sent with `send` runs and gets no reply; a reply waiting at stop is reported as `MessageNotAnswered` and freed (step 3).
- Photosphere (`main-state.test.zig`): a message answered by a task gets the result and the page hears the task end; a task end with no waiting reply sends none; a reply waiting at stop is freed. `logging.test.zig` uses `logDetailsTaskData`. Every existing message test passes with the same replies (step 4).

## Smoke Tests

- Ziggy `mise exec -- bun run test:smoke`: `10-pickers` drives the three pick messages, each now a handler that starts a task by a call and is answered from `on_task_end`; `desktop-only/25-close-with-dialog-open` quits with a pick task waiting on a dialog.
- Photosphere `bun run test:ziggy` against the local Ziggy (step 4's four commands): every scenario sends converted messages (pickers, vault, databases, config and state, saving assets).

## Verify

Ziggy, from its root:

- `mise exec -- bun run compile`, `mise exec -- bun run compile:zig`, `mise exec -- bun run test`, `mise exec -- bun run test:zig`, `mise exec -- bun run test:smoke`.
- `mise exec -- bun run test:zig:android` and `mise exec -- bun run test:smoke:android`, because the core changed (Ziggy's rule that a core change is tested on the mobile suites).
- No `.task` variant and no path that queues a task from a return value remains. Each of these prints no line:
  - `grep -rnE 'ResponseTask|reply_id_json|emitReply|queueResponseTask|next_request_task|MessageHasNoId|respondedByTask|\.task = \.\{' --include='*.zig' --exclude-dir=zig-pkg --exclude-dir=.zig-cache --exclude-dir=node_modules --exclude-dir=worktrees --exclude-dir=tmp packages apps`
  - `grep -nE '^\s+task: ' packages/ziggy/core/src/lib/handlers.zig`
  - `grep -rnE '\.task\b.*(variant|result|holding)|\.\{ \.task = |"request"' --exclude-dir=plans docs apps/ziggy-template/.claude`

Photosphere, from `../photosphere`:

- `mise exec -- zig build test --fork=../ziggy --summary all --test-timeout 20m`.
- The four smoke test commands at the end of step 4.
- `grep -rn '\.task = \.{' packages-zig apps --include='*.zig'` and `grep -rn 'returns `.task`\|return `.task`' docs` print no line.

Not run by this plan:

- iOS suites (`test:zig:ios`, `test:smoke:ios` in Ziggy, `test:ziggy:ios` in Photosphere): macOS only.
- Photosphere `bun run test:ziggy:and`: `apps/photosphere/scripts/sync-android.sh` runs `zig build photosphere-backend` with no fork option and Gradle takes Ziggy's Android native app from the git tag, so it cannot build against `../ziggy`. It runs once Photosphere moves to the Ziggy release that holds this change.
- Photosphere `bun run test:zig` and `bun run test:everything` as scripts: they build against the tagged Ziggy, which lacks `sendTaskEnd` until that release.
- Photosphere `bun run test` and `bun run compile` (TypeScript) and `bun run test:cli:zig` are unaffected: no TypeScript changes and the CLI sends no messages.

## Notes

- The human's decisions:
  - No documentation step at the start and no review stop. Step 1 is implementation; step 5, the last implementation step, writes the docs.
  - How a slow message gets its reply: "Same as every other thing that does it." Read from the code, that is `Response(T).later` with the handler's `Reply(T)`, which the handler keeps, posting a `later-reply` that `LaterReplies.deliver` sends. The handler starts its task with `services.addTask`, keeps the reply keyed by the task's id and returns `.later`; `on_task_end` sends the response. No new reply mechanism.
  - Tasks are never created from a handler's return value: the `.task` variant is gone from `Response` and `MessageResult`, with every core path that queued a task from it, then Verify's grep checks it.
- Smallest additions to Ziggy, then why: `Reply(T).sendTaskEnd` because `on_task_end` has the task's error only as text (already described by the worker) and `Reply.fail` takes a Zig error; `ziggy.core.ReplyTarget` exported so one map holds replies of every `Result`. Both use `postLaterReply` and change no wire format.
- Photosphere keeps its replies in `MainState`, the main thread's existing state, so it adds no global. The Ziggy test app has no state and a handler and `on_task_end` share only the standard arguments, so it gets one `threadlocal` record of waiting replies, which Ziggy's Tasks guide ("Threads and state") names as where main-thread state lives; it carries the comment `rules/general.md` requires. The core's own test app needs none, because its tests that used the task-reply messages for other behaviour queue the tasks with `add-task` instead.
- The source `"request"`: Ziggy no longer has it, because the app queues the task and chooses the source. Photosphere uses `"request"` (`MESSAGE_TASK_SOURCE`), so `cancelTasks("request")` keeps cancelling every task answering a message. The Ziggy test app uses `"pickers"`. A cancelled task still gives the error reply `Cancelled`, a failed one its error text or `Failed`.
- Behaviour that changes, decided: a message task now sends the frontend a `task-completed` event like any task (Photosphere's and the test app's listeners match on their own task ids or types, checked in `jobs.ts`, `import-context.tsx`, `app-context.tsx`, `asset-database-source.tsx`, `task-queue.ts` and the test app's `main.ts`); a message sent with `send` is no longer refused with `MessageHasNoId`, its task runs and gets no response; a reply still waiting when the backend stops is reported as `MessageNotAnswered` (before, the reply was dropped at shutdown); the response data passes through the main thread's JSON parse in `LaterReplies.deliver`, so it is the same JSON value though number spelling can differ (`1.0` comes back as `1`).
- The reply reaches the page after `onTaskEnd`'s own state changes, because the reply is posted to the main thread's queue; before, it went out ahead of them.
- Rejected: a core-side `addTask` that takes a reply (it is the removed path under another name); putting the reply in the task's input (a `ReplyTarget` holds a queue pointer, which JSON cannot carry); deleting the test app's pick messages and queuing their tasks from the frontend (it leaves no end-to-end test of a message answered from a task).
- Moving Photosphere's locked Ziggy tag (`build.zig.zon`, `apps/photosphere-frontend/package.json`, Gradle and Xcode) to a new Ziggy release and moving the two examples to it, are outside this plan. The plan does no release, tag, push or commit.
- Ziggy's `docs/user-guide/messages.md` and `tasks.md` have staged changes from the human; edit the files as they are on disk and leave the git state alone.
