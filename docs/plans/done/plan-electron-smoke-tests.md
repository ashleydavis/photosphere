# Electron Smoke Tests

> **IMPORTANT:** Keep all code changes minimal and easy to diff. Do not refactor surrounding code, rename existing things, or make changes beyond what each step strictly requires.

## Overview
Add an initial smoke test suite for the Electron desktop app as a starting point. The shell structure and coordinator are inspired by `apps/cli/smoke-tests.sh` (numbered tests, parallel batches, fuzzy name selection, pass/fail summary), but the internals differ significantly: the CLI tests are largely sequential and share state across tests, whereas these tests are fully isolated — each is a self-contained script in its own directory that can be run independently or as part of a batch.

**Controlling the app.** A lightweight HTTP test-control server is added to the Electron main process and started only when `PHOTOSPHERE_TEST_MODE=1` is set. It listens on a port supplied via `PHOTOSPHERE_TEST_PORT`. Shell scripts send control commands by posting JSON to this server with `curl`. The server responds with `{ ok: true }` or `{ ok: false, error: string }`.

The following control actions are required:

- **Click a menu item** — trigger a native application menu action (e.g. File > New Database) by its menu item ID. The main process already handles menu actions and sends the resulting `menu-action` IPC message to the renderer; the test control server calls the same handler directly.
- **Click a button** — send a message to the renderer to click a UI element identified by a `data-id` attribute. Elements that need to be scriptable from tests must have a `data-id` added to their JSX. The renderer listens for a `test-click` IPC message, looks up the element by `data-id`, and calls `.click()` on it.
- **Type text** — send a message to the renderer to populate an input field, also identified by `data-id`. The renderer listens for a `test-type` IPC message and sets the field value.
- **Navigate to a page** — the main process already sends `navigate` IPC messages to the renderer to change the active page; the test control server calls the same code path.

In addition to these UI-level actions, the server also exposes higher-level semantic endpoints that invoke existing IPC handlers directly in the main process without going through the renderer UI: create a database at a given path, open an existing database by path, and import a list of asset file paths. These bypass file-picker dialogs and make tests deterministic.

All endpoints respond with `{ ok: true }` or `{ ok: false, error: string }`. Additional control endpoints can be added as more tests are written.

**Observing behaviour.** The app is launched as a background subprocess with all output (stdout and stderr) redirected to `app.log` inside that test's own `tmp/` directory (e.g. `smoke-tests/2-create-database/tmp/app.log`). Key events in the main process emit `log.info` messages — for example `Main window created`, `Database created: <path>`, `Database opened: <name>`, `Import task completed` — and these are the signals tests wait for and assert on. Tests use `wait_for_log` to poll the log for an expected pattern and `check_no_errors` to assert no `[ERROR]` lines were written.

For this to work fully, all output from worker processes and the renderer must reach the main process and appear in `app.log`. Structured log messages sent through the `log` abstraction already travel via IPC and are handled. But raw console output (`console.log`, `console.warn`, `console.error`) from workers and the renderer does not — it either disappears or goes to a separate DevTools console. In test mode, this output must also be captured and forwarded. The plan is to override `console` in each process when `NODE_ENV=testing` is set: worker processes patch `console` to send each call as a log IPC message via `parentPort.postMessage`; the renderer patches `console` to forward via the existing `renderer-log` IPC channel. Whether this is fully achievable (particularly for the renderer, where third-party libraries may call console before the patch is applied) needs to be verified during implementation.

**App changes required.** Four categories of change are needed before the test suite can run: (1) add the HTTP test-control server; (2) add `uncaughtException` / `unhandledRejection` handlers to the main process, workers, and renderer so all unhandled errors reach the log; (3) respect `PHOTOSPHERE_CONFIG_DIR`, `PHOTOSPHERE_VAULT_DIR`, and `PHOTOSPHERE_VAULT_TYPE` env vars so each test runs with fully isolated state; (4) add targeted `log.info` calls for the events tests need to assert on.

Six tests cover the most critical flows. Each lives in its own subdirectory under `apps/desktop/smoke-tests/` with its own `tmp/` directory; multiple tests can run in parallel because each uses a distinct port and temp directory.

## Isolation and execution model

Each test is a standalone script at `apps/desktop/smoke-tests/<N>-<name>/test.sh`. It has no knowledge of any other test and no dependency on test state left behind by a previous run. Everything a test needs — temp database, config dir, vault dir, app log — lives under its own `tmp/` subdirectory, created fresh at the start of the test and ignored by git. The test launches its own Electron instance, exercises it, and shuts it down before exiting. A test can therefore be run on its own at any time:

```
bash apps/desktop/smoke-tests/3-open-database/test.sh

```

**Sequential execution.** `smoke-tests.sh --sequential` runs each `test.sh` one at a time, in numeric order, waiting for each to finish before starting the next. This is the simplest mode and the easiest to debug.

**Parallel batch execution.** `smoke-tests.sh` (the default) runs tests in batches of N (default 2, configurable via `--parallel N`). Within each batch, tests run concurrently as background shell jobs. The coordinator waits for all jobs in the batch to finish before starting the next batch. Because each test owns a unique port (selected via `find_free_port` before the app is launched) and a unique `tmp/` directory, concurrent tests never interfere with each other.

**Single test execution.** `smoke-tests.sh <X>` runs the test whose number or name (fuzzy-matched against the directory name) matches `X`. If multiple names match the fuzzy pattern, all matching tests are run.

The coordinator pre-bundles the app once (`bun run bundle`) before dispatching any tests, so individual `test.sh` scripts can launch `electron .` directly without rebundling.

## Tests

| # | Name | What it tests |
|---|---|---|
| 1 | `1-load-fixture` | Opens the 50-asset database fixture, waits for the gallery to load, and asserts the `Gallery loaded: 50 assets` log message confirming all 50 assets were rendered. Asserts no `[ERROR]` lines were written. |
| 2 | `2-create-database` | Triggers File > New Database from the menu, types the database path into the path input, clicks confirm, waits for the `Database created` log message, and checks the `.db` directory exists on disk. |
| 3 | `3-open-database` | Pre-creates an empty database with the CLI, then opens it in the app via File > Open Database: types the path into the dialog input, clicks confirm, and waits for the `Database opened` log message and the gallery to load. |
| 4 | `4-import-photos` | Pre-creates a database with the CLI and opens it via the API (setup only), then clicks the Import button in the UI, types the path of the test images directory into the import dialog, clicks confirm, and waits for the `Import task completed` log message followed by a `Gallery loaded: 3 photos` message confirming the gallery updated. |
| 5 | `5-add-secret` | Navigates to the Secrets page via the sidebar, clicks Add Secret, types a name and value into the form fields, clicks confirm, and waits for the `Secret added` log message confirming the vault was updated. |
| 6 | `6-add-database-entry` | Navigates to the Databases page via the sidebar, clicks Add Database, types a name and path for a pre-existing database (created with the CLI) into the form, clicks confirm, and waits for the `Database entry added` log message confirming the entry was saved. |

## smoke-tests.sh subcommands

All commands are run from `apps/desktop/`.

| Invocation | Behaviour |
|---|---|
| `./smoke-tests.sh` | Runs all tests in parallel batches of 2 (the default). |
| `./smoke-tests.sh all` | Same as no argument. |
| `./smoke-tests.sh --sequential` | Runs all tests one at a time in numeric order. |
| `./smoke-tests.sh --parallel [N]` | Runs all tests in parallel batches of N (default 2 if N omitted). |
| `./smoke-tests.sh <X>` | Runs a single test. `X` may be a number (`3`) or a fuzzy name (`open`, `import`). If multiple tests match the fuzzy name, all matching tests are run. |
| `./smoke-tests.sh ls` | Lists all discovered tests with their number and name. No tests are run. |
| `./smoke-tests.sh list` | Same as `ls`. |
| `./smoke-tests.sh help` | Prints usage information. |
| `./smoke-tests.sh --help` | Same as `help`. |
| `./smoke-tests.sh -?` | Same as `help`. |
| `./smoke-tests.sh --?` | Same as `help`. |

**No subcommand (default behaviour).** Running `./smoke-tests.sh` with no arguments pre-bundles the app once, then runs all tests in parallel batches of 2, prints a live pass/fail line for each test as it completes, and exits with a summary in the CLI style. Exit code is 0 if all tests pass, 1 if any fail.

## Issues

## Steps

### Phase 1 — App changes: test control server

1. **`apps/desktop/src/lib/test-control-server.ts`** — Create a new file implementing `ITestControlServer` interface and `TestControlServer` class. When instantiated it starts an HTTP server on the port given by `PHOTOSPHERE_TEST_PORT` env var. Endpoints:
   - `GET /ready` — returns `200 OK` once the main window has loaded.
   - `POST /navigate` — body `{ page: string }` — sends a `navigate` IPC message to the renderer via `mainWindow.webContents.send`, using the same code path the application menu already uses.
   - `POST /create-database` — body `{ path: string }` — invokes the existing `create-database-at-path` IPC handler directly in-process.
   - `POST /open-database` — body `{ path: string }` — invokes `notify-database-opened` in-process.
   - `POST /import-assets` — body `{ paths: string[] }` — queues an import task via the worker pool.
   - `POST /quit` — calls `app.quit()`.
   All endpoints respond with `{ ok: true }` on success or `{ ok: false, error: string }` on failure.

2. **`apps/desktop/src/main.ts`** — After `createMainWindow()`, if `PHOTOSPHERE_TEST_MODE=1` is set, create a `TestControlServer` instance, passing it the `mainWindow` and worker pool references. Store on a module-level variable so it is not GC'd. Log `Test control server listening on port <N>` when it starts.

### Phase 2 — App changes: unhandled error capture (all modes)

3. **`apps/desktop-frontend/src/index.tsx`** — Add `window.addEventListener('error', ...)` and `window.addEventListener('unhandledrejection', ...)` handlers that call `window.electronAPI.log({ level: 'error', message, error })` so renderer errors reach the main process log. Additionally, when `NODE_ENV=testing`, patch `console.log`, `console.warn`, and `console.error` as early as possible in the entry point to forward each call via `window.electronAPI.log` so raw renderer console output also appears in `app.log`. Note that output from third-party code loaded before this patch runs may not be captured; this is a best-effort measure.

4. **`apps/desktop/src/worker.ts`** — Add `process.on('uncaughtException', ...)` and `process.on('unhandledRejection', ...)` handlers that forward via `parentPort?.postMessage({ type: 'log', level: 'error', message, error })`. Additionally, when `NODE_ENV=testing`, patch `console.log`, `console.warn`, and `console.error` at the top of the file to forward each call as a log message via `parentPort.postMessage` so raw console output from workers appears in `app.log`.

5. **`apps/desktop/src/rest-api-worker.ts`** — Same as step 4: unhandled error handlers and `console` patching in test mode.

6. **`apps/desktop/src/main.ts`** — Add `process.on('uncaughtException', ...)` and `process.on('unhandledRejection', ...)` handlers that call `log.error(...)` near the top of the file before `app.whenReady()`.

### Phase 3 — App changes: test isolation via env vars

7. **`apps/desktop/src/main.ts`** — Read `PHOTOSPHERE_CONFIG_DIR` and `PHOTOSPHERE_VAULT_DIR` environment variables and use them to override the default config and vault directory paths when set. Also read `PHOTOSPHERE_VAULT_TYPE` to allow tests to use the `plaintext` vault. Identify the config storage and vault code paths (`get-config` / `set-config` / `vault-*` IPC handlers) and thread the overrides through.

### Phase 4 — App changes: key log messages for test assertions

8. **`apps/desktop/src/main.ts`** — Add explicit `log.info` calls for the events tests will assert on:
   - After `createMainWindow()` completes: `log.info('Main window created')`
   - In `create-database` / `create-database-at-path` IPC handler on success: `log.info('Database created: <path>')`
   - In `notify-database-opened` handler: `log.info('Database opened: <name>')`
   - In the worker `task-completed` handler when task type is `import`: `log.info('Import task completed')`

### Phase 5 — Shared bash infrastructure

9. **`apps/desktop/smoke-tests/lib/common.sh`** — Shared helpers sourced by every `test.sh`:
   - `log_info`, `log_success`, `log_error` — coloured output matching CLI smoke-test style.
   - `print_test_header <number> <name>` — double-line banner.
   - `find_free_port` — finds a free TCP port (using Python one-liner or `/dev/tcp` probe).
   - `start_app <port> <tmp_dir>` — bundles and launches `electron . --no-sandbox` with `PHOTOSPHERE_TEST_MODE=1`, `PHOTOSPHERE_TEST_PORT=<port>`, `PHOTOSPHERE_CONFIG_DIR=<tmp_dir>/config`, `PHOTOSPHERE_VAULT_DIR=<tmp_dir>/vault`, `PHOTOSPHERE_VAULT_TYPE=plaintext`, `NODE_ENV=testing`; redirects stdout+stderr to `<tmp_dir>/app.log`; stores PID in `<tmp_dir>/app.pid`.
   - `wait_for_ready <port> [timeout_secs]` — polls `GET http://localhost:<port>/ready` until 200 or timeout; exits 1 on timeout.
   - `wait_for_log <tmp_dir> <pattern> [timeout_secs]` — tails `<tmp_dir>/app.log` until `pattern` matches or timeout.
   - `send_command <port> <endpoint> [json_body]` — wraps `curl -sf -X POST http://localhost:<port>/<endpoint>` with JSON body; exits 1 on non-zero curl exit or `ok:false` response.
   - `stop_app <tmp_dir>` — sends `POST /quit`, waits for the PID in `<tmp_dir>/app.pid` to exit, then kills it if still running.
   - `check_no_errors <tmp_dir>` — greps `<tmp_dir>/app.log` for `[ERROR]`; fails if any are found.

10. **`apps/desktop/smoke-tests/.gitignore`** — Add `*/tmp/` to ignore test temp directories.

### Phase 6 — Individual tests

11. **`apps/desktop/smoke-tests/1-load-fixture/test.sh`** — *50-asset fixture loads and renders*:
    - Clean `tmp/`, `find_free_port`, `start_app`, `wait_for_ready`.
    - Call `send_command $PORT open-database '{"path":"<abs_path_to_fixture>"}'` pointing at the 50-asset database fixture in `test/fixture-50/`.
    - Call `wait_for_log ./tmp 'Gallery loaded: 50 assets'`.
    - Call `check_no_errors ./tmp`.
    - Call `stop_app ./tmp`.

12. **`apps/desktop/smoke-tests/2-create-database/test.sh`** — *Create a database*:
    - Clean `tmp/`, `find_free_port`, `start_app`, `wait_for_ready`.
    - Call `send_command $PORT menu '{"itemId":"new-database"}'`.
    - Call `wait_for_log ./tmp 'Create database dialog opened'`.
    - Call `send_command $PORT type '{"dataId":"database-path-input","text":"<abs_tmp>/test-db"}'`.
    - Call `send_command $PORT click '{"dataId":"create-database-confirm"}'`.
    - Call `wait_for_log ./tmp 'Database created'`.
    - Check that `tmp/test-db/.db` exists on disk.
    - Call `check_no_errors ./tmp`.
    - Call `stop_app ./tmp`.

13. **`apps/desktop/smoke-tests/3-open-database/test.sh`** — *Open a pre-created database*:
    - Clean `tmp/`, pre-create database with CLI (`psi init --db <abs_tmp>/test-db --yes`).
    - `find_free_port`, `start_app`, `wait_for_ready`.
    - Call `send_command $PORT menu '{"itemId":"open-database"}'`.
    - Call `wait_for_log ./tmp 'Open database dialog opened'`.
    - Call `send_command $PORT type '{"dataId":"database-path-input","text":"<abs_tmp>/test-db"}'`.
    - Call `send_command $PORT click '{"dataId":"open-database-confirm"}'`.
    - Call `wait_for_log ./tmp 'Database opened'`.
    - Call `check_no_errors ./tmp`.
    - Call `stop_app ./tmp`.

14. **`apps/desktop/smoke-tests/4-import-photos/test.sh`** — *Import photos*:
    - Clean `tmp/`, pre-create database with CLI, open it via `send_command $PORT open-database` (setup only).
    - Call `wait_for_log ./tmp 'Database opened'`.
    - Call `send_command $PORT click '{"dataId":"import-button"}'`.
    - Call `wait_for_log ./tmp 'Import dialog opened'`.
    - Call `send_command $PORT type '{"dataId":"import-path-input","text":"<abs_path_to_test_images>"}'`.
    - Call `send_command $PORT click '{"dataId":"import-confirm"}'`.
    - Call `wait_for_log ./tmp 'Import task completed'`.
    - Call `wait_for_log ./tmp 'Gallery loaded: 3 photos'`.
    - Call `check_no_errors ./tmp`.
    - Call `stop_app ./tmp`.

15. **`apps/desktop/smoke-tests/5-add-secret/test.sh`** — *Add a secret*:
    - Clean `tmp/`, `find_free_port`, `start_app`, `wait_for_ready`.
    - Call `send_command $PORT navigate '{"page":"secrets"}'`.
    - Call `wait_for_log ./tmp 'Secrets page loaded'`.
    - Call `send_command $PORT click '{"dataId":"add-secret-button"}'`.
    - Call `wait_for_log ./tmp 'Add secret dialog opened'`.
    - Call `send_command $PORT type '{"dataId":"secret-name-input","text":"test-secret"}'`.
    - Call `send_command $PORT type '{"dataId":"secret-value-input","text":"test-value"}'`.
    - Call `send_command $PORT click '{"dataId":"add-secret-confirm"}'`.
    - Call `wait_for_log ./tmp 'Secret added'`.
    - Call `check_no_errors ./tmp`.
    - Call `stop_app ./tmp`.

16. **`apps/desktop/smoke-tests/6-add-database-entry/test.sh`** — *Add a database entry*:
    - Clean `tmp/`, pre-create database with CLI.
    - `find_free_port`, `start_app`, `wait_for_ready`.
    - Call `send_command $PORT navigate '{"page":"databases"}'`.
    - Call `wait_for_log ./tmp 'Databases page loaded'`.
    - Call `send_command $PORT click '{"dataId":"add-database-button"}'`.
    - Call `wait_for_log ./tmp 'Add database dialog opened'`.
    - Call `send_command $PORT type '{"dataId":"database-name-input","text":"My Test DB"}'`.
    - Call `send_command $PORT type '{"dataId":"database-path-input","text":"<abs_tmp>/test-db"}'`.
    - Call `send_command $PORT click '{"dataId":"add-database-confirm"}'`.
    - Call `wait_for_log ./tmp 'Database entry added'`.
    - Call `check_no_errors ./tmp`.
    - Call `stop_app ./tmp`.

### Phase 7 — Coordinator script

16. **`apps/desktop/smoke-tests.sh`** — Main coordinator. Behaviour:
    - Discovers all tests by globbing `smoke-tests/*/test.sh` sorted numerically.
    - Parses test number and name from the directory name (`N-kebab-name`).
    - Supports subcommands / flags:
      - `ls` / `list` — prints numbered test list.
      - `help` / `--help` / `-?` / `--?` — prints usage.
      - `all` or no argument — runs all tests (default: parallel batches of 2).
      - `--sequential` — runs tests one at a time.
      - `--parallel [N]` — runs N tests at a time (default 2).
      - `X` — runs single test by number or fuzzy name; if multiple fuzzy matches, runs all.
    - Tracks pass/fail per test and prints a summary in the CLI style.
    - Pre-bundles the app once (`bun run bundle` from `apps/desktop`) before launching any tests.

17. **`apps/desktop/package.json`** — Add `"test:smoke-e2e": "./smoke-tests.sh"` to scripts.

## Unit Tests

- No new unit tests for the bash infrastructure.
- For app code changes in Phases 1–4:
  - `apps/desktop-frontend/src/test/error-handling.test.ts` — Mock `window.electronAPI.log` and verify it is called when an `ErrorEvent` is dispatched on `window`.
  - `apps/desktop/src/test/main-error-handling.test.ts` — Verify the `uncaughtException` listener calls `log.error` (mock the logger).

## Smoke Tests

The plan creates its own smoke tests, which are the deliverable. Manual checks after implementation:

1. `cd apps/desktop && ./smoke-tests.sh list` — prints 5 tests.
2. `./smoke-tests.sh 1` — test 1 (app-starts) passes in isolation.
3. `./smoke-tests.sh app` — fuzzy match runs test 1.
4. `./smoke-tests.sh --sequential` — all 5 tests run one at a time.
5. `./smoke-tests.sh` — all 5 tests run in parallel batches of 2, all pass.
6. `./smoke-tests.sh --parallel 3` — runs 3 at a time.
7. `./smoke-tests.sh help` — prints usage.
8. Introduce a deliberate renderer error; verify `[ERROR]` appears in `app.log` and `check_no_errors` catches it.

## Verify

- `cd apps/desktop && bun run compile` — TypeScript compiles without errors after all app changes.
- `cd apps/desktop && bun run bundle` — bundles cleanly.
- Root `bun run compile` — no TypeScript errors across workspace.
- `cd apps/desktop && ./smoke-tests.sh --sequential` — all 6 tests pass one at a time.
- `cd apps/desktop && ./smoke-tests.sh` — all 6 tests pass in parallel batches of 2.
- `cd apps/desktop && ./smoke-tests.sh --parallel 3` — all 6 tests pass in parallel batches of 3.

The project is not considered finished until all smoke tests pass in both sequential and parallel modes.

## Notes

- **No Playwright**: these tests are pure bash, identical in spirit to the CLI smoke tests. The existing Playwright-based tests in `tests/smoke.spec.ts` remain unchanged.
- **Test control server**: only started when `PHOTOSPHERE_TEST_MODE=1`. It should never be compiled into production builds; guard with a runtime env-var check, not a build-time flag.
- **Port allocation**: each `test.sh` picks its own free port via `find_free_port` before launching the app, so parallel tests never collide.
- **Stdout capture**: the app is launched with `> app.log 2>&1 &` so all output (main process, forwarded worker logs, forwarded renderer logs) lands in one file that `wait_for_log` and `check_no_errors` can inspect.
- **Bundling once**: `smoke-tests.sh` runs `bun run bundle` once before spawning parallel test processes, so each test.sh can skip rebundling and just launch `electron .`.
- **navigate log message**: the `/navigate` endpoint in `TestControlServer` should log `Navigated to <page>` after executing the JS so test 5 has a reliable pattern to wait for.
- **Electron binary vs dev bundle**: tests default to launching via `electron . --no-sandbox` against the dev bundle. A `--binary` flag can be added later (mirroring the CLI) to launch the built release binary.
- **Windows/macOS**: bash is required. Works on macOS/Linux natively; on Windows use Git Bash or WSL.
