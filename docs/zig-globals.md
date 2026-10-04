# Global variables in the Zig port

Every global listed here must be considered for removal. None of them is approved to stay. Each one is to be reviewed on its own, and the value passed down from whoever owns it instead.

Top-level variables come from running the plan's audit command against the `zig-2` branch, before any change (`git grep -nE '^(pub )?(threadlocal )?var '` over `apps/cli-zig` and `packages-zig`, excluding tests, `aws` and `zlib-ng`). Line numbers are those of `zig-2`. The struct-level variables at the end are from the plan, because that part of the audit is a manual read.

## Top-level variables

### apps/cli-zig

- `src/lib/clack/prompts/common.zig`: `stdin_buffer` (153), `stdin_reader` (158), `stdin_input` (163), `stdout_buffer` (168), `stdout_writer` (173)
- `src/lib/log.zig`: `fileLogger` (43)
- `src/lib/picocolors.zig`: `detected_support` (82), `support_override` (87)
- `src/lib/process-argv.zig`: `process_argv` (12)
- `src/lib/process-signals.zig`: `registrations` (55), `registrationCount` (60), `listenersLock` (65), `pendingSignals` (70), `watcherStarted` (75), `wakePipe` (81)
- `src/lib/worker-log-bun.zig`: `workerLogInstance` (173, thread-local), `main_log` (205), `routing_log_state` (227)

### packages-zig/api-zig

- `src/lib/media-source.zig`: `lastDeleteErrorSourceIds` (123, thread-local)

### packages-zig/lan-share-network-zig

- `src/lib/socket.zig`: `winsockStarted` (138)

### packages-zig/node-api-zig

- `src/lib/hash-cache.zig`: `loadedHashCaches` (1321, thread-local)
- `src/lib/media-source-registry.zig`: `mediaSourceBuilders` (43), `mediaSourceBuildersLock` (48)
- `src/lib/third-party/mime/index.zig`: `defaultMime` (21), `defaultMimeState` (27)

### packages-zig/node-utils-zig

- `src/lib/process-env.zig`: `environ_map` (13)
- `src/lib/termination.zig`: `terminationCallbacksInitialized` (18), `terminationCallbacks` (37), `pendingSignal` (97), `signalIo` (102), `signalPipe` (109), `signalEvent` (115)

### packages-zig/storage-zig

- `src/lib/s3-client.zig`: `last_http_status_code` (22, thread-local), `library_mutex` (127), `library_initialized` (132), `interned_error_names_mutex` (318), `interned_error_names` (324)

### packages-zig/task-queue-zig

- `src/lib/queue-backend.zig`: `_backend` (145)
- `src/lib/worker.zig`: `handlers` (24)

### packages-zig/utils-zig

- `src/lib/console.zig`: `stdout_mutex` (16), `captured_stdout` (21), `captured_stderr` (26)
- `src/lib/errors.zig`: `last_error` (67, thread-local)
- `src/lib/log.zig`: `console_log` (279), `log` (284, public)

### packages-zig/vault-zig

- `src/lib/get-vault.zig`: `vaultInstances` (24), `vaultInstancesMutex` (29)
- `src/lib/keychain-types.zig`: `spawn_function` (78)
- `src/lib/linux-keychain-vault.zig`: `toolChecked` (26)
- `src/lib/windows-keychain-vault.zig`: `toolChecked` (22)

## Struct-level variables, from the plan

- `packages-zig/tools-zig/src/lib/video.zig`: `ffprobeCommand`, `ffmpegCommand`, `isInitialized`
- `packages-zig/tools-zig/src/lib/image.zig`: `convertCommand`, `identifyCommand`, `isInitialized`, `imageMagickType`
