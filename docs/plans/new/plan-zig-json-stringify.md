# Replace handwritten JSON in the Zig code with std.json

## Overview

Photosphere's Zig code writes some JSON text out as literal characters instead of serialising a value: string literals such as `"{\"type\":\"shutdown\"}"`, format strings such as `"{{\"type\":\"connection\",\"socket\":{d}}}"`, and runs of `writeAll("{\"lat\":")` calls. It also reads some JSON by searching the text for a fragment such as `"\"socket\":"` instead of parsing it. Handwritten JSON does not escape what it interpolates (a quote or a backslash in a path or an error message produces invalid JSON), it drifts from the struct that reads it back, and fragment searches break when field order or spacing changes. This plan replaces every such site with the idiomatic Zig equivalent of `JSON.stringify` and `JSON.parse`: `std.json.Stringify` (through Ziggy's `json.stringify` and `json.stringifyComptime` helpers) on a named struct, and `std.json.parseFromSlice` into a named struct. No new helper module is needed: Ziggy already provides the helpers, and every Photosphere package module imports `ziggy`.

## Issues

## Steps

Helpers used throughout (all verified in Ziggy v0.0.23, the version `build.zig.zon` locks):

- `@import("ziggy").json.stringify(allocator, value) ![]u8`: compact JSON, null optional fields left out.
- `@import("ziggy").json.stringifyComptime(comptime value) []const u8`: the same, at compile time. A call inside a runtime function must be written `comptime json.stringifyComptime(...)` or it fails with "unable to resolve comptime value" (checked by running it).
- `@import("ziggy").json.Raw{ .text = ... }`: already-built JSON text placed into a value given to stringify, written as it is.
- `@import("utils-zig").json` is Ziggy's `utils.json`: it has `stringify` and `Raw` but not `stringifyComptime`.
- `@import("ziggy").worker_messages.IWorkerShutdownMessage`: Ziggy's struct for the worker `shutdown` message, whose `type` field defaults to `"shutdown"`.
- `std.json.Stringify.valueAlloc(allocator, value, options)`, `std.json.fmt(value, options)` and `std.json.Stringify.encodeJsonStringChars(chars, options, writer)` from Zig 0.16's standard library. `std.json` writes an `f64` holding a whole number as an integer (`1762300000000`, `3`) and a fraction in its shortest form (`-33.8688`, `0.1`), and `.whitespace = .indent_2` writes `{\n  "name": "N",\n  "message": "m\"x"\n}` (both checked by running them).

Every new struct gets a `//` comment block above it and a `//` comment on each field, and its name starts with `I` (project code style). Each step ends with its listed tests passing; run them as `mise exec -- zig build test -Dtest-file=<package>/<file>.test.zig` for package tests and `mise exec -- zig build test -Dcli-test-file=<file>.test.zig` for CLI tests.

1. **Worker pool shutdown messages and failed-task log** (`apps/cli-zig/src/lib/worker-pool.zig`).
    - At the two `workerState.worker.postMessage(io, "{\"type\":\"shutdown\"}")` calls, pass `comptime json.stringifyComptime(worker_messages.IWorkerShutdownMessage{})` instead. `json` (`ziggy.json`) and `worker_messages` (`ziggy.worker_messages`) are already imported at the top of the file.
    - In the `task-completed` branch, replace the `std.fmt.allocPrint(arena, "Task {s} failed with error {{\n  \"name\": ...` call with `std.fmt.allocPrint(arena, "Task {s} failed with error {f}", .{ taskId, std.json.fmt(failure_detail, .{ .whitespace = .indent_2 }) })`, where `failure_detail` is an `IFailedTaskDetail` value holding the same name (`failure.name`, or `"Error"` when `result.@"error"` is null) and message (`result.errorMessage orelse ""`).
    - Add `IFailedTaskDetail` near the top of the file: a struct with `name: []const u8` and `message: []const u8`, in that order, so the output keeps its current field order and layout.
    - In `apps/cli-zig/src/test/worker-pool.test.zig`, add a handler `failingQuotedHandler` that returns `utils.errors.throwError("bad \"quote\"", .{})`, register it in `test_tasks` as `"fail-quoted"`, and add the test listed under Unit Tests.
    - Run `-Dcli-test-file=worker-pool.test.zig`.

2. **Retry's verbose error log** (`packages-zig/utils-zig/src/lib/retry.zig`, `logVerboseError`).
    - Replace `fixed_writer.print("Error: {{\n  \"name\": {f},\n  \"message\": {f}\n}}", ...)` with `fixed_writer.print("Error: {f}", .{std.json.fmt(IVerboseErrorDetail{ .name = ..., .message = ... }, .{ .whitespace = .indent_2 })})`.
    - Add `IVerboseErrorDetail` above `logVerboseError`: `name: []const u8` then `message: []const u8`.
    - The existing test "should log the error of a failed attempt when verbose logging is enabled" in `packages-zig/utils-zig/src/test/retry.test.zig` asserts the exact output and must pass unchanged. Run `-Dtest-file=utils-zig/retry.test.zig`.

3. **HTTP server queue messages** (`packages-zig/node-utils-zig/src/lib/http-server.zig`).
    - Add `IQueueSignal`: a struct with one field `type: []const u8`, for the server's own `stop`, `free` and `request` messages.
    - Replace each `"{\"type\":\"stop\"}"`, `"{\"type\":\"free\"}"` and `"{\"type\":\"request\"}"` literal posted to a queue (in `HttpServer.stop`, the shutdown loop over `connections`, `stopAccepting`, `connectionMain` and `serveConnection`) with `comptime json.stringifyComptime(IQueueSignal{ .type = "stop" })` and the like. `json` is already imported in this file.
    - Add `IConnectionMessage`: `type: []const u8 = "connection"` and `socket: u64`. Rewrite `connectionMessage` to return `json.stringify(allocator, IConnectionMessage{ .socket = handleNumber(stream.socket.handle) })`.
    - Rewrite `isType(text, comptime message_type)` as `isType(allocator, text, comptime message_type)`: parse `text` with `std.json.parseFromSlice(IQueueSignal, allocator, text, .{ .ignore_unknown_fields = true })`, compare `parsed.value.type` with `message_type`, `deinit` the result. A message that does not parse panics with a message naming the text, since every message on these queues is made by Photosphere's own code and the owner's messages (`HttpServer.post`) are objects with a `type` (as `http-server.test.zig` posts them).
    - Rewrite `socketOf(text)` as `socketOf(allocator, text)`: parse into `IConnectionMessage` with `.ignore_unknown_fields = true`, panic when it does not parse, and convert `socket` to a handle as it does today. Give `streamOf` the same `allocator` parameter and pass it to `socketOf`.
    - Update every call site of `isType`, `socketOf` and `streamOf` to pass the allocator already in scope there (`Request.waitForMessage`'s `allocator` parameter, the `allocator` local of `serverMain` and `connectionMain`, and the `allocator` parameter of `handleServerMessage` and `stopRequested`).
    - Rewrite the comment above `isType`: it no longer reads the text without parsing it.
    - Run `-Dtest-file=node-utils-zig/http-server.test.zig`, then the test files of the servers built on it: `-Dtest-file=mcp-zig/streamable-http.test.zig`, `-Dtest-file=node-api-zig/asset-server-routes.test.zig` and `-Dtest-file=photosphere-core/mcp-server.test.zig`.

4. **LAN share receiver responses** (`packages-zig/lan-share-network-zig/src/lib/lan-share-receiver.zig`, `handleRequest`).
    - Add to `packages-zig/lan-share-network-zig/src/lib/lan-share-types.zig`, beside `IPairingCodeHashResponse`: `IErrorResponse` (`@"error": []const u8`) and `ISuccessResponse` (`success: bool`).
    - Import `const json = @import("ziggy").json;` at the top of `lan-share-receiver.zig` and alias the two new types as `IPairingCodeHashResponse` is aliased.
    - Replace the literal bodies with `comptime json.stringifyComptime(IErrorResponse{ .@"error" = "Too many requests" })`, `"Invalid JSON"`, `"Invalid pairing code"`, `"Not found"` and `comptime json.stringifyComptime(ISuccessResponse{ .success = true })`.
    - The tests in `packages-zig/lan-share-network-zig/src/test/lan-share-receiver.test.zig` that assert `{"error":"Invalid JSON"}` and `{"error":"Not found"}` must pass unchanged. Run `-Dtest-file=lan-share-network-zig/lan-share-receiver.test.zig` and `-Dtest-file=lan-share-network-zig/lan-share-sender.test.zig`.

5. **Native call replies** (`packages-zig/photosphere-core/src/lib/macos-native-calls.zig`, `packages-zig/photosphere-core/src/lib/windows-native-calls.zig`, `apps/photosphere/native/linux/src/main.zig`).
    - In each `call`/`nativeCall`, return `comptime json.stringifyComptime(INotificationPermission{ .granted = true })` for `requestNotificationPermission`, `comptime json.stringifyComptime("unknown")` for `networkConnectionType` and `comptime json.stringifyComptime(null)` where `"null"` is returned.
    - Add `INotificationPermission` (`granted: bool`) to each of the three files beside its `IHoldAwake`. Import `const json = @import("ziggy").json;` in the macOS and Windows files.
    - `apps/photosphere/native/linux/src/main.zig` is built by Ziggy's build with only the `ziggy-native-linux` import, so there use `comptime std.fmt.comptimePrint("{f}", .{std.json.fmt(value, .{})})` in place of `stringifyComptime`.
    - Leave the `holdAwake needs {{"awake": true or false}}` error texts as they are: they are messages to a person describing a request, not JSON the code sends.
    - Run `mise exec -- zig build photosphere-linux` and `mise exec -- zig build photosphere-windows-check`, then `-Dtest-file=photosphere-core/macos-native-calls.test.zig` and `-Dtest-file=photosphere-core/windows-native-calls.test.zig`.

6. **Image location log** (`packages-zig/node-api-zig/src/lib/image.zig`, `locationJson`).
    - Add `ILocationJson`: `lat: ?f64` and `lng: ?f64`.
    - Rewrite `locationJson` to build an `ILocationJson` whose field is the coordinate when `std.math.isFinite` holds and null otherwise, and return `std.json.Stringify.valueAlloc(allocator, value, .{ .emit_null_optional_fields = true })`, so NaN is still written as `null` as `JSON.stringify` writes it.
    - `writeJsonNumber` is left with no caller (`locationJson` is its only one); it is removed in the Clean up step.
    - The tests in `packages-zig/node-api-zig/src/test/image.test.zig` asserting `{"lat":95,"lng":10.5}` and `{"lat":null,"lng":null}` must pass unchanged. Run `-Dtest-file=node-api-zig/image.test.zig`.

7. **Sort index checkpoint** (`packages-zig/bdb-zig/src/lib/sort-index.zig`, `saveCheckpoint`).
    - Replace the `writeAll` sequence with `std.json.Stringify.valueAlloc(self.allocator, checkpoint.*, .{ .emit_null_optional_fields = true })`. `IBuildCheckpoint`'s fields are declared in the order the file has today (`completedShards`, `currentShard`, `currentShardRecordIndex`, `totalRecordsProcessed`, `lastUpdated`), and `loadCheckpoint` already parses the same struct, so the text round-trips through one type.
    - In `packages-zig/bdb-zig/src/test/memory-storage.zig`, add a field `writes: std.ArrayList(IWrittenFile) = .empty` (with `IWrittenFile` holding `path` and `data`) and append a copy of each path and data in `MemoryStorage.write`, so a test can read files that a build writes and later deletes. This is test code only.
    - Add the sort-index test listed under Unit Tests. Run `-Dtest-file=bdb-zig/sort-index.test.zig`.

8. **Virtual time moves** (`packages-zig/utils-zig/src/test/virtual-time-io.zig`, `move`).
    - Add `IClockMove`: `jumped_nanoseconds: i64`.
    - Replace the `std.fmt.bufPrint(&buffer, "{{\"jumped_nanoseconds\":{d}}}", ...)` with `std.json.Stringify.value(IClockMove{ .jumped_nanoseconds = jumped }, .{}, &fixed_writer)` on a `std.Io.Writer.fixed(&buffer)` and post `fixed_writer.buffered()`.
    - Run `-Dtest-file=node-api-zig/database-reachable-timeout.test.zig` (it parses these messages) and `-Dtest-file=utils-zig/retry.test.zig`.

9. **CLI test helper events** (`apps/cli-zig/src/test/test-helpers.zig`, `BlockingTaskQueues.runBlockingTask` and `BlockingTaskCount.readEvents`).
    - Add `IBlockingTaskEvent`: `type: []const u8`.
    - Post `comptime ziggy.json.stringifyComptime(IBlockingTaskEvent{ .type = "started" })` and the `"ended"` equivalent.
    - In `readEvents`, parse each message with `std.json.parseFromSlice(IBlockingTaskEvent, allocator, message.text, .{})`, `deinit` it, and compare `type` with `"started"` and `"ended"`; keep the panic for any other type.
    - Run the CLI test files that use `BlockingTaskQueues` (`grep -l BlockingTask apps/cli-zig/src/test/*.zig` lists them) with `-Dcli-test-file=`.

10. **photosphere-core test support replies** (`packages-zig/photosphere-core/src/test/test-support.zig`, `requestOk` and `requestError`).
    - Add `IReplyOk` (`ok: bool`, `data: std.json.Value`) and `IReplyError` (`ok: bool`, `@"error": []const u8`).
    - In `requestOk`, parse the reply with `std.json.parseFromSlice(IReplyOk, allocator, reply, .{ .ignore_unknown_fields = true, .parse_numbers = false })`; when it does not parse or `ok` is false, print the reply as today and return `error.RequestFailed`; otherwise return `json.stringify(allocator, parsed.value.data)`. `.parse_numbers = false` keeps each number as its original text (`.number_string`), so the data's numbers come back byte for byte.
    - In `requestError`, parse into `IReplyError` the same way; return `error.RequestSucceeded` when it does not parse or `ok` is true; otherwise return a copy of the `error` field.
    - Leave the fragments given to `FakeNativeApp.indexOfContaining` and `expectMessageContaining` (`reply_start`, `failed`, the `FINAL_CONSOLE_TYPE` marker): Ziggy's fake native app matches messages only by substring, so those are search patterns, not JSON the code builds or reads.
    - Run every photosphere-core test file (`mise exec -- zig build test -Dtest-file=photosphere-core/<file>.test.zig` for each file `grep -l 'requestOk\|requestError' packages-zig/photosphere-core/src/test/*.zig` lists).

11. **JSON built with format strings in test files.** In each site below, build the value as a named struct (or a `std.json.ObjectMap` where the fields vary) and write it with `ziggy.json.stringify` or `std.json.Stringify.valueAlloc`; where a part is already JSON text, put it in as `json.Raw{ .text = ... }`. Each file's tests must pass unchanged after the edit; run each with `-Dtest-file=` or `-Dcli-test-file=`.
    - `apps/cli-zig/src/test/mcp-tools.test.zig`: the `open_database` arguments (`path`) and the two `export` argument objects (`assetId`, `outputPath`, `type`). Pass the unescaped paths; drop the `escapedPath` and `escapedRoot` replacements that only existed to feed them.
    - `apps/cli-zig/src/test/commands.test.zig`, `jsonEscapedPath`: replace the `std.mem.replaceOwned` body with `std.json.Stringify.encodeJsonStringChars(path, .{}, &output.writer)` on a `std.Io.Writer.Allocating`, so every character JSON escapes is escaped, not only backslashes.
    - `packages-zig/api-zig/src/test/auto-import-mobile.test.zig` and `packages-zig/mobile-worker-zig/src/test/plan-auto-import.worker.test.zig`, `settingsWith`/the settings builder: a struct with `enabled: bool` and `sources: json.Raw`.
    - `packages-zig/lan-share-network-zig/src/test/lan-share-sender.test.zig`: the `codeHash` body, using `IPairingCodeHashResponse` from `lan-share-types.zig`.
    - `packages-zig/mcp-zig/src/test/streamable-http.test.zig`: the over-limit `ping` payload, as a struct with `jsonrpc`, `id`, `method` and `params: struct { x: []const u8 }`. The body must still be over `streamable_http.JSON_BODY_LIMIT`.
    - `packages-zig/node-api-zig/src/test/apply-database-ops.test.zig`: `minimalAssetJson`, `groupingOp`, `setOpFor` and the inline op builders. Add `IOpJson` (`databaseId`, `collectionName`, `recordId`, `op: json.Raw`) and build the inner `op` objects and the asset fields as structs; change `minimalAssetJson`'s `extra` fragment parameter to take the extra fields as a `std.json.ObjectMap` merged into the asset's fields, and update its callers.
    - `packages-zig/node-api-zig/src/test/asset-server-core.test.zig`: the op text, using the same approach.
    - `packages-zig/node-api-zig/src/test/database-reachable-timeout.test.zig`: the two S3 credential values (`region`, `accessKeyId`, `secretAccessKey`, `endpoint`), with `endpoint` built by `std.fmt.allocPrint` as a plain string first.
    - `packages-zig/node-utils-zig/src/test/fs.test.zig`, `JsonCountMutator.run`: a struct with `count` and `pad`, where `pad` is a string of `x` characters of the same length the loop builds today.
    - `packages-zig/storage-zig/src/test/file-storage-locks.test.zig`: the BOM lock file. Stringify a struct with `owner`, `acquiredAt` and `timestamp`, then concatenate `"\u{FEFF}"`, that text and `"\u{3000}"`, so the test still checks the BOM and trailing whitespace handling.
    - `packages-zig/photosphere-core/src/test/mcp-server.test.zig`, `answerRequest`: change its last parameter from a members fragment to `result: ?[]const u8, error_message: ?[]const u8`, build `.{ .kind = "app", .name = "mcp-tool-response", .data = IToolResponseData{ ... } }` with `IToolResponseData` holding `requestId`, `result: ?[]const u8 = null` and `@"error": ?[]const u8 = null`, write it with `json.stringify` (which leaves out the null one) and update its callers. Leave the `marker` in `waitForRequest`: it is a substring pattern for `expectMessageContaining`.

12. **Sweep for anything left.** Run these searches over the Zig sources and confirm each hit is one of the exclusions listed in Notes:
    - `git ls-files '*.zig' | grep -v test-jpg-exif | xargs grep -nE '\\\\"[a-zA-Z_]+\\\\":|\{\{\\\\"'`
    - `git ls-files '*.zig' | xargs grep -nE 'writeAll\("[\[\]\{\}:,]+"\)'`
    Convert any hit that is not an exclusion the same way as the steps above.

13. **Run the whole affected set.** Run `mise exec -- bun run test:everything` (plain, no `--force`) and fix every failure at its cause.

14. **Documentation.**
    - Create `docs/zig-json.md`, "JSON in the Zig code". It says: JSON is always written from a named struct with `ziggy.json.stringify` (or `utils.json.stringify`), and a constant message with `comptime ziggy.json.stringifyComptime(...)`; JSON text that is already built goes in as `json.Raw`; JSON is read with `std.json.parseFromSlice` or `parseFromSliceLeaky` into a named struct, with `.ignore_unknown_fields = true` where the sender adds fields; `.emit_null_optional_fields` is passed explicitly whenever a null must be written; the native Linux app uses `std.json` directly because it imports only `ziggy-native-linux`. It names the deliberate exceptions and why: `bdb-zig`'s `js-value.zig` and `json-stable-stringify.zig` and `mcp-zig`'s `protocol.zig` write `BsonValue`s the way JavaScript's `JSON.stringify` and the npm `json-stable-stringify` package do, byte for byte, because stored hashes depend on it; and test files keep literal JSON for fixtures and expected output, so a test checks exact bytes.
    - Add a line linking to it in the Guides list of `docs/development.md`.

15. **Clean up.**
    - Delete the function `writeJsonNumber` and its comment block from `packages-zig/node-api-zig/src/lib/image.zig`. Zig does not report an unused function, so confirm with `grep -n writeJsonNumber packages-zig/node-api-zig/src/lib/image.zig` that no reference is left, then run `-Dtest-file=node-api-zig/image.test.zig` and `mise exec -- zig build test` again.

## Unit Tests

- `apps/cli-zig/src/test/worker-pool.test.zig`: new test "a failed task's error is logged as an indented JSON object when verbose logging is on". It runs `fail-quoted` with a `MemoryLog` made with `.verbose = true`, captures the console with `utils.console.setCapture` as "a worker that fails to start is logged and replaced, and its task waits" does, and asserts stdout contains `failed with error {\n  "name": "Error",\n  "message": "bad \"quote\""\n}`. This fails against the old code, which wrote the quote unescaped.
- `packages-zig/utils-zig/src/test/retry.test.zig`: existing exact-output test of `logVerboseError` covers step 2.
- `packages-zig/node-utils-zig/src/test/http-server.test.zig`: existing tests (stop, connection hand-over, owner messages for a key, connection thread pool) cover `isType`, `socketOf`, `streamOf` and `connectionMessage`, which are private to the file.
- `packages-zig/lan-share-network-zig/src/test/lan-share-receiver.test.zig`: existing tests assert the `Invalid JSON` and `Not found` bodies, and the status codes of the 429 and success cases but not their bodies. Add `try std.testing.expectEqualStrings("{\"error\":\"Too many requests\"}", ...)` on the last response's body to "aborts and returns 429 after exceeding the request budget" (keep the last response, not only its `statusCode`), and `try std.testing.expectEqualStrings("{\"success\":true}", response.body)` to "accepts payload with correct code hash".
- `packages-zig/node-api-zig/src/test/image.test.zig`: existing tests of the out-of-range and NaN location log lines cover `locationJson`.
- `packages-zig/bdb-zig/src/test/sort-index.test.zig`: new test "build writes a checkpoint after each shard that loadCheckpoint can read". It builds an index over `testRecords`, takes the last `build.checkpoint` entry from `fixture.storage.writes`, asserts it starts with `{"completedShards":[`, parses it into a local struct with the five checkpoint fields and asserts `completedShards` is non-empty, `currentShard` is null and `currentShardRecordIndex` is 0.
- `packages-zig/node-api-zig/src/test/database-reachable-timeout.test.zig`: existing tests parse the virtual time moves (step 8).
- CLI tests using `BlockingTaskQueues` cover step 9.
- photosphere-core tests using `requestOk` and `requestError` cover step 10.
- `apps/cli-zig/src/test/commands.test.zig`: "mcp answers an MCP session" covers `jsonEscapedPath`.
- `packages-zig/photosphere-core/src/test/macos-native-calls.test.zig` and `windows-native-calls.test.zig`: existing tests assert the exact replies `{"granted":true}`, `"unknown"` and `null`, and cover step 5 unchanged.
- The Linux native app's `nativeCall` has no unit test (it is built only by Ziggy's build); `bun run test:ziggy` on Linux covers it.

## Smoke Tests

- `bun run test:cli:zig`: the Zig CLI smoke suite runs the worker pool (shutdown messages, task failure output), the LAN share receive and the MCP server over the HTTP server.
- `bun run test:ziggy`: the Photosphere App on the host operating system, which on Linux runs `apps/photosphere/native/linux/src/main.zig`'s native calls and the asset server.
- Both run as part of `bun run test:everything` in step 13.

## Verify

- `mise exec -- zig build test` exits 0 (every Zig unit test).
- `mise exec -- zig build photosphere-linux` and `mise exec -- zig build photosphere-windows-check` exit 0.
- `mise exec -- bun run test:everything` exits 0, which covers compile, the Zig unit tests, the Zig CLI smoke tests, the Photosphere App on the host and on Android.
- The two searches in step 12 return only the exclusions listed in Notes.
- CI-only: the macOS and iOS builds of the Photosphere App (`macos-native-calls.zig` runs only there; on Linux it compiles under the photosphere-core tests).

## Notes

- The human chose no documentation review stop: implementation starts at step 1 and the documentation is written in step 14.
- Ziggy's helpers are used as they are in the locked v0.0.23. No change to Ziggy is needed, so no Ziggy release or local path link is involved.
- Excluded on purpose: `packages-zig/bdb-zig/src/lib/js-value.zig` (`writeJsonString`, `jsonStringifyIndented`, `writeJsonIndented`), `packages-zig/bdb-zig/src/lib/json-stable-stringify.zig` and `packages-zig/mcp-zig/src/lib/protocol.zig` (`writeCompact`). They are general serialisers of `BsonValue` that copy JavaScript's number formatting, lone-surrogate escaping and key sorting byte for byte, because the hashes of stored records depend on that output. `std.json` formats some numbers differently (`1e21` as `1000000000000000000000` where JavaScript writes `1e+21`, checked by running it), so they cannot move to it.
- Excluded on purpose: literal JSON in `*.test.zig` files used as a fixture or as expected output, and `packages-zig/node-api-zig/src/test/test-jpg-exif.zig` (the expected `JSON.stringify(tags, null, 2)` of a photo). Expected output must be literal so the test checks exact bytes. Only test code that builds JSON with a format string or a writer is converted (step 11).
- Excluded on purpose: substring patterns given to Ziggy's `FakeNativeApp` (`indexOfContaining`, `expectMessageContaining`, `countContaining`, `removeContaining`), which matches messages only by substring.
- Excluded on purpose: log and error texts that quote a value with `\"{s}\"` (for example `Failed to check file "{s}"`). They are messages to a person, not JSON.
- `std.json` writes optional nulls by default; Ziggy's `json.stringify` leaves them out. Where a null must appear (`currentShard` in the checkpoint, NaN coordinates), the plan passes `.emit_null_optional_fields = true` to `std.json` explicitly, as the general coding rules require options to be passed explicitly.
- `packages-zig/utils-zig/src/lib/json.zig` is a copy of Ziggy's `utils/src/lib/json.zig` that `utils-zig/src/index.zig` does not use (it exports `ziggy_utils.json`). It is out of scope for this plan.
