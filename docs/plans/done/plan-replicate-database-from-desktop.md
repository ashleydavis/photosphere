# Replicate Database from the Manage Databases Page

## Overview
Add a "Replicate" action to each row on the Manage Databases page so the desktop user can clone a registered database to a new location without dropping to the CLI. The button opens a Replicate dialog that lets the user pick a destination path, choose between **Full** and **Partial** replication (defaulting to Partial), and explains what each mode does.

The actual replication work cannot run in the Electron main process — it is a long-running, BSON/merkle-tree-heavy operation that must happen in the worker pool (the same pool that already runs `sync-database`, `import-assets`, etc.). The plan therefore extracts a new `replicate-database` background task that wraps the existing pure `replicate()` function in [packages/api/src/lib/replicate.ts](packages/api/src/lib/replicate.ts) — exactly the same function the CLI's `replicateCommand` in [apps/cli/src/cmd/replicate.ts](apps/cli/src/cmd/replicate.ts) already calls. No replication logic is duplicated — only the orchestration layer (credential resolution, storage construction, registration of the destination as a new entry) is added on the worker side.

After a successful replication, the destination is added to `databases.json` automatically so the user can open it from the same page.

## Issues
<!-- populated later by plan:check -->

## Steps

### 1. Add the `replicate-database` background task

**1a. Create the task data type.**
- New file: `packages/api/src/lib/replicate-database.types.ts`.
- Export an interface `IReplicateDatabaseData` with:
  - `sourcePath: string` — the source database path (already in `databases.json`, so source credentials are resolved via `resolveStorageCredentials`).
  - `destPath: string` — destination path (filesystem or `s3:` path).
  - `destEncryptionKeyId: string | undefined` — vault secret id of an encryption key to use at the destination, or undefined for an unencrypted destination / using the same key as source when destination already exists.
  - `destS3KeyId: string | undefined` — vault secret id of S3 credentials to use when `destPath` starts with `s3:`.
  - `partial: boolean` — true for partial replication, false for full.
  - `force: boolean` — true to allow replication when destination exists with a different database id.
- Export an interface `IReplicateProgressMessage` with:
  - `type: "replicate-progress"`.
  - `databasePath: string` — the source database path (used by the UI to discard messages from a closed or different replication).
  - `progress: string` — the human-readable progress string emitted by `replicate()`.

**1b. Create the worker handler.**
- New file: `packages/api/src/lib/replicate-database.worker.ts`.
- Export `replicateDatabaseHandler(data: IReplicateDatabaseData, context: ITaskContext): Promise<void>`. Model it on [packages/api/src/lib/sync-database.worker.ts](packages/api/src/lib/sync-database.worker.ts) — same imports (`createStorage`, `loadEncryptionKeysFromPem`, `resolveStorageCredentials`, `createMediaFileDatabase`, `log`).
- Body:
  1. Validate `data.sourcePath` and `data.destPath`.
  2. Resolve source credentials: `const { s3Config: sourceS3, encryptionKeyPems: sourcePems } = await resolveStorageCredentials(data.sourcePath);`. Build `sourceStorage` and `sourceRawStorage` with `createStorage(data.sourcePath, sourceS3, sourceStorageOptions)`. Build `sourceBsonDatabase` via `createMediaFileDatabase(sourceStorage, ...).bsonDatabase` so it matches what the CLI passes into `replicate()`.
  3. Resolve destination credentials directly from the vault (do NOT go through `resolveStorageCredentials` because the destination is not yet in `databases.json`):
      - If `data.destS3KeyId` is set, use `getVault(getDefaultVaultType()).get(...)` to load the S3 secret JSON exactly the same way [apps/desktop/src/main.ts:392-401](apps/desktop/src/main.ts#L392-L401) does in the `get-database-secrets` handler.
      - If `data.destEncryptionKeyId` is set, use `parseEncryptionKeyFromVaultValue` (export it from [packages/api/src/lib/resolve-storage-credentials.ts](packages/api/src/lib/resolve-storage-credentials.ts) — it is currently a private function — and re-export it from `packages/api/src/index.ts`).
      - Construct `destStorageOptions` via `loadEncryptionKeysFromPem(destPems)` and build `destStorage` and `destRawStorage` with `createStorage(data.destPath, destS3, destStorageOptions)`.
  4. Forward progress: pass a `progressCallback` that calls `context.sendMessage({ type: "replicate-progress", databasePath: data.sourcePath, progress })`.
  5. Call `await replicate(sourceStorage, sourceBsonDatabase, context.uuidGenerator, context.timestampProvider, destStorage, destRawStorage, { force: data.force, partial: data.partial }, progressCallback)`.
  6. If `destPems.length > 0` (destination is encrypted), write `.db/encryption.pub` to `destRawStorage` using the same logic as [apps/cli/src/cmd/replicate.ts:288-294](apps/cli/src/cmd/replicate.ts#L288-L294).
  7. Return — `replicate()` already calls `updateDatabaseConfig` to set `origin` and `lastReplicatedAt`.

**1c. Register the handler.**
- File: [packages/api/src/lib/task-handlers.ts](packages/api/src/lib/task-handlers.ts).
- Add `import { replicateDatabaseHandler } from "./replicate-database.worker";` and `registerHandler("replicate-database", replicateDatabaseHandler);` next to the existing `sync-database` registration.

**1d. Re-export the worker types.**
- File: [packages/api/src/index.ts](packages/api/src/index.ts).
- Add `export * from "./lib/replicate-database.worker";` and `export * from "./lib/replicate-database.types";`.

### 2. Wire up Electron IPC for replicate-database

**2a. Add IPC handler in main.ts.**
- File: [apps/desktop/src/main.ts](apps/desktop/src/main.ts).
- After the existing `import-assets` IPC handler, add a new handler that enqueues the replicate task and adds the destination to `databases.json` once the task completes:
  ```ts
  ipcMain.handle('replicate-database', logExceptions(async (_event, request: IReplicateDatabaseRequest) => {
      if (!workerPool) {
          throw new Error('Worker pool not initialized');
      }
      const taskId = workerPool.addTask("replicate-database", {
          sourcePath: request.sourcePath,
          destPath: request.destPath,
          destEncryptionKeyId: request.destEncryptionKeyId,
          destS3KeyId: request.destS3KeyId,
          partial: request.partial,
          force: request.force ?? false,
      }, request.sourcePath);
      return { taskId };
  }, 'Error starting replicate-database'));
  ```
- Define `IReplicateDatabaseRequest` in [packages/electron-defs/src/lib/electron-api.ts](packages/electron-defs/src/lib/electron-api.ts) so it can be shared with the renderer.
- In the existing `workerPool.onTaskComplete` callback in `initWorkers()`, add a branch:
  ```ts
  if (result.type === "replicate-database") {
      const inputs = result.inputs as IReplicateDatabaseData;
      if (result.status === TaskStatus.Succeeded) {
          // Add the new replica to databases.json so it shows up on the Manage Databases page.
          const existing = (await getDatabases()).find(entry => entry.path === inputs.destPath);
          if (!existing) {
              await addDatabaseEntry({
                  name: basename(inputs.destPath),
                  description: '',
                  path: inputs.destPath,
                  origin: inputs.sourcePath,
                  encryptionKey: inputs.destEncryptionKeyId,
                  s3Key: inputs.destS3KeyId,
              });
          }
          if (mainWindow) {
              mainWindow.webContents.send('show-notification', {
                  message: `Replication completed for "${basename(inputs.destPath)}"`,
                  color: 'success',
              });
          }
      }
      else if (mainWindow) {
          mainWindow.webContents.send('show-notification', {
              message: `Replication failed: ${result.errorMessage || 'Unknown error'}`,
              color: 'danger',
              duration: 8000,
          });
      }
  }
  ```
- Add the import for `IReplicateDatabaseData` from `api`.

**2b. Add the preload bridge.**
- File: [apps/desktop/src/preload.ts](apps/desktop/src/preload.ts).
- Add `replicateDatabase: (request: IReplicateDatabaseRequest) => ipcRenderer.invoke('replicate-database', request)` to the `electronAPI` object, and update the `IElectronAPI` interface in [packages/electron-defs/src/lib/electron-api.ts](packages/electron-defs/src/lib/electron-api.ts) with the matching signature `replicateDatabase: (request: IReplicateDatabaseRequest) => Promise<{ taskId: string }>;`.

### 3. Surface replicate in the platform context

**3a. Extend `IPlatformContext`.**
- File: [packages/user-interface/src/context/platform-context.tsx](packages/user-interface/src/context/platform-context.tsx).
- Add a new interface `IReplicateDatabaseRequest` mirroring the Electron one (sourcePath, destPath, destEncryptionKeyId, destS3KeyId, partial, force).
- Add a method `replicateDatabase: (request: IReplicateDatabaseRequest) => Promise<{ taskId: string }>;` to `IPlatformContext`.

**3b. Implement in the Electron platform provider.**
- File: [apps/desktop-frontend/src/lib/platform-provider-electron.tsx](apps/desktop-frontend/src/lib/platform-provider-electron.tsx).
- Add `const replicateDatabase = useCallback(async (request: IReplicateDatabaseRequest) => electronAPI.replicateDatabase(request), [electronAPI]);` and include it in the `platformContext` object.

**3c. Implement in the web platform provider.**
- File: [apps/dev-frontend/src/lib/platform-provider-web.tsx](apps/dev-frontend/src/lib/platform-provider-web.tsx).
- Provide a stub that throws `"Replication is only available on desktop"` (mirror how other Electron-only methods like `importAssets` degrade on web — check the existing file for the exact pattern and match it).

### 4. Build the Replicate dialog

**4a. Create the dialog component.**
- New file: `packages/user-interface/src/components/replicate-database-dialog.tsx`.
- Use Joy UI primitives consistent with the other dialogs ([packages/user-interface/src/components/share-database-dialog.tsx](packages/user-interface/src/components/share-database-dialog.tsx) and [packages/user-interface/src/components/view-database-dialog.tsx](packages/user-interface/src/components/view-database-dialog.tsx)).
- Props:
  ```ts
  export interface IReplicateDatabaseDialogProps {
      open: boolean;
      sourceEntry: IDatabaseEntry;
      encryptionSecrets: ISharedSecretEntry[];
      s3Secrets: ISharedSecretEntry[];
      onClose: () => void;
  }
  ```
- Internal state machine `step: "configure" | "running" | "success" | "error"`.
- Form state:
  - `destPath: string` — initial value `''`.
  - `mode: "partial" | "full"` — initial value `"partial"`.
  - `destEncryptionKeyId: string | undefined`.
  - `destS3KeyId: string | undefined`.
- "Configure" step shows:
  - Read-only display of `sourceEntry.name` and `sourceEntry.path`.
  - A path input + **Browse** button that calls `platform.pickFolder()` (reuse the same pattern as in [packages/user-interface/src/pages/databases/databases-page.tsx:222-227](packages/user-interface/src/pages/databases/databases-page.tsx#L222-L227)).
  - A `RadioGroup` (Joy UI `<RadioGroup>` with `<Radio>` children) for **Partial** vs **Full**, with helper text under each:
    - **Partial** (default): "Copies only metadata and structure. Original photos and videos are fetched on demand from the source. Choose this when you want a small, browsable replica."
    - **Full**: "Copies everything — every original, display, and thumbnail file. Choose this when you want a complete, standalone copy that does not depend on the source."
  - A **Destination encryption key** selector (Joy UI `<Select>`) populated from `encryptionSecrets`, with a "None" option. (Mirror the `renderSecretSelector` helper in `databases-page.tsx`, but rendered inline — no need for a "+ New" button in v1.)
  - A **Destination S3 credentials** selector populated from `s3Secrets`, only rendered when `destPath` starts with `s3:`.
  - Action buttons: **Cancel** and **Start replication** (disabled when `destPath` is empty or equal to `sourceEntry.path`).
- On **Start replication**:
  - Set `step = "running"`.
  - Call `platform.replicateDatabase({...form, sourcePath: sourceEntry.path, partial: mode === "partial"})` and store the returned `taskId` in `useRef`.
  - Subscribe to `platform.onTaskMessage` and `platform.onTaskComplete` filtered by that `taskId`. On `replicate-progress` messages update a `progress` string in state. On task completion: `step = "success"` (or `"error"` with `result.errorMessage`).
- "Running" step shows a `<CircularProgress />` plus the latest progress string.
- "Success" step shows an Alert with the destination path; the action becomes a single **Close** button. Closing fires the `onClose` callback and the parent reloads the database list (so the new replica appears).
- "Error" step shows an Alert with the message and a **Close** button.
- Cancellation is out of scope for v1: the **Cancel** button on the configure step closes the dialog; once running the dialog only shows a progress view (no cancel). Document this in the **Notes** section below.
- Add `data-id` attributes for smoke-test selectors:
  - `replicate-database-dialog`, `replicate-dest-path-input`, `replicate-dest-browse-button`, `replicate-mode-partial`, `replicate-mode-full`, `replicate-start-button`, `replicate-cancel-button`, `replicate-close-button`.

**4b. Wire the dialog into the Manage Databases page.**
- File: [packages/user-interface/src/pages/databases/databases-page.tsx](packages/user-interface/src/pages/databases/databases-page.tsx).
- Add a state hook `const [replicatingEntry, setReplicatingEntry] = useState<IDatabaseEntry | undefined>(undefined);`.
- Import `ReplicateDatabaseDialog` from `'../../components/replicate-database-dialog'`.
- In the icon column (around line 346), insert a new `<IconButton>` between the existing **Share** and **Edit** buttons:
  ```tsx
  <IconButton
      data-id="replicate-database-button"
      size="sm"
      variant="plain"
      title="Replicate database"
      onClick={() => { log.info('Replicate database dialog opened'); setReplicatingEntry(entry); }}
  >
      <ContentCopy fontSize="small" />
  </IconButton>
  ```
- Add `ContentCopy` to the existing `@mui/icons-material` import (line 19).
- At the end of the JSX (next to the other modal renders, around line 531), add:
  ```tsx
  {replicatingEntry !== undefined && (
      <ReplicateDatabaseDialog
          open={replicatingEntry !== undefined}
          sourceEntry={replicatingEntry!}
          encryptionSecrets={encryptionSecrets}
          s3Secrets={s3Secrets}
          onClose={() => {
              setReplicatingEntry(undefined);
              loadData().catch(err => log.exception('Failed to reload data:', err as Error));
          }}
      />
  )}
  ```
- Update the table header `Actions` column width if needed (currently `140px`) so the new button fits without wrapping.

### 5. Refactor the CLI to keep code shared

The destination-credential-resolution helper in the new worker is a near-duplicate of one branch of the CLI's `replicateCommand`. To honor the user's "share code with the CLI" requirement:

- Move the small destination-credential building logic out of [apps/cli/src/cmd/replicate.ts](apps/cli/src/cmd/replicate.ts) into a new exported helper `buildDestStorageFromCredentialIds(destPath: string, destEncryptionKeyId: string | undefined, destS3KeyId: string | undefined)` in `packages/api/src/lib/replicate-destination.ts`. The helper returns `{ destStorage, destRawStorage, destPems }` and is called from both:
  - the new `replicate-database.worker.ts` (Step 1b.3), and
  - the CLI's `replicateCommand` once `options.destKey` and any S3 credentials have been resolved into vault ids.
- Re-export the helper from `packages/api/src/index.ts`.
- Verify the CLI still passes its existing tests after this refactor.

### 6. Round out the type exports
- File: [packages/electron-defs/src/lib/electron-api.ts](packages/electron-defs/src/lib/electron-api.ts).
- Ensure `IReplicateDatabaseRequest` is exported so it can be imported from both `apps/desktop/src/preload.ts` and `apps/desktop-frontend/src/lib/platform-provider-electron.tsx`.
- File: [packages/user-interface/src/index.ts](packages/user-interface/src/index.ts) (or wherever the re-exports live) — re-export `IReplicateDatabaseRequest` and `ReplicateDatabaseDialog` if external consumers need them. Confirm by grep first; if no external import is needed, skip.

## Unit Tests

### `replicate-database.worker.test.ts` (new file)
- File: `packages/api/src/test/lib/replicate-database.worker.test.ts`.
- Mock `./resolve-storage-credentials` so `resolveStorageCredentials` returns deterministic values, mock the `vault` module so `getVault().get(...)` returns canned secret JSON, and mock `./replicate` so `replicate` is a `jest.fn()` resolving to `{ filesImported: 0, copiedFiles: 0, copiedRecords: 0, prunedFiles: [] }`.
- Test cases:
  - **`forwards source path through resolveStorageCredentials and constructs source storage with the resolved credentials`** — assert the mocked `resolveStorageCredentials` was called once with `data.sourcePath`.
  - **`loads destination encryption key from the vault when destEncryptionKeyId is provided`** — assert `vault.get(data.destEncryptionKeyId)` was called and the resulting key pair was passed into `loadEncryptionKeysFromPem`.
  - **`skips destination encryption key resolution when destEncryptionKeyId is undefined`** — assert `vault.get` was not called for encryption.
  - **`loads destination S3 credentials when destPath starts with "s3:" and destS3KeyId is provided`**.
  - **`forwards partial flag to replicate()`** — assert `replicate` was called with `{ partial: true }` (and another test for `{ partial: false }`).
  - **`emits a replicate-progress task message for each progress callback fired by replicate()`** — capture the `progressCallback` arg passed into `replicate`, invoke it twice, assert `context.sendMessage` was called twice with the matching `IReplicateProgressMessage` shape (including `databasePath: data.sourcePath`).
  - **`writes encryption.pub to dest raw storage when destination is encrypted`** — assert `destRawStorage.write` was called with `'.db/encryption.pub'`.

### `replicate-database-dialog.test.tsx` (new file, optional)
- File: `packages/user-interface/src/test/components/replicate-database-dialog.test.tsx` (only if a sibling test file exists for `share-database-dialog.tsx`; check first with `find packages/user-interface/src/test -name "*-dialog.test.tsx"`. If no sibling pattern exists, skip the React-side unit tests and rely on the smoke test).

### Refactor tests
- If Step 5 introduced `buildDestStorageFromCredentialIds`, add tests for it: a vault stub, an in-memory mock filesystem, and assertions on the returned `destPems` for the cases (a) no encryption, (b) encryption only, (c) encryption + S3.

## Smoke Tests

Add a new desktop smoke test directory: `apps/desktop/smoke-tests/16-replicate-database/test.sh`. Model it on [apps/desktop/smoke-tests/10-view-database/test.sh](apps/desktop/smoke-tests/10-view-database/test.sh).

The test should:
1. Pre-create a source database via the CLI and import a small fixture (use `psi init` then `psi add <fixture-photo>`).
2. Start the desktop app in test mode and navigate to the Databases page.
3. Click `add-database-button`, fill `database-path-input` with the source path, and click `add-database-confirm`. Wait for `Database entry added`.
4. Click `replicate-database-button` on the only row. Wait for `Replicate database dialog opened`.
5. `type` into `replicate-dest-path-input` with the test's destination path.
6. Click `replicate-mode-partial` (already the default; clicking it asserts the radio is interactive).
7. Click `replicate-start-button`. Wait for a log line `Replication completed for` (emitted by the show-notification path in main.ts, which already writes via the file logger).
8. Verify on disk that `<destPath>/.db/files.dat`, `<destPath>/.db/config.json` exist, and `.db/config.json` parses to JSON with `origin === <sourcePath>`.
9. Run a second sub-case for **Full** mode: repeat steps 3–8 with a different destination path and `replicate-mode-full`. Verify that `<destPath>/.db/bson/...` is fully populated (a non-trivial check; for a minimal smoke test it suffices to assert `<destPath>/.db/files.dat` exists and is non-empty).
10. `check_no_errors` and `stop_app`.

Update the desktop smoke test runner index (e.g. the script in `apps/desktop/scripts/` that enumerates smoke test directories) only if it does not auto-discover `16-*`. Most likely auto-discovers — confirm by reading the runner script.

## Verify
1. `bun run compile` from repo root — all TypeScript compiles cleanly.
2. `bun run test` from repo root — full unit test suite passes, including the new `replicate-database.worker.test.ts`.
3. `bun run test:cli` from repo root — CLI smoke tests still pass (the CLI replicate refactor in Step 5 must not regress existing behavior).
4. `bun run test:electron` from repo root — Electron smoke tests pass, including the new `16-replicate-database`.

## Human Verification
1. Start the desktop app (`bun run dev`). Add an existing on-disk database via **Add database** on the Databases page.
2. Click the **Replicate** icon on that row. Confirm the dialog opens with the source name displayed and **Partial** preselected.
3. Pick a fresh empty folder as the destination, click **Start replication**. Confirm a progress indicator appears, then a success notification. Confirm the new replica appears as a row on the Databases page with `origin` set to the source path.
4. Verify on disk that the destination contains a `.db/` directory but no `asset/`, `display/` directories beyond what partial mode requires.
5. Repeat with **Full** mode against another fresh folder. Confirm asset/display/thumb files are present in the destination.
6. Open the resulting replica via the **Open** button on the Databases page. Confirm the gallery loads.
7. Try replicating to a destination that already exists with a *different* database id (e.g. another initialized database). Confirm the worker fails with a clear error notification (we don't expose `force` in v1, so this should just fail gracefully).

## Notes
- **Why a new task type and not reuse `sync-database`?** Sync is bidirectional and assumes both sides already exist; replicate is the one-way create-or-overwrite operation used to seed a new replica. They share the underlying merkle-tree comparison machinery but not the orchestration semantics.
- **Why not call `replicate()` directly from the main process?** Replication walks the entire BSON merkle tree and copies hundreds-to-millions of asset files. The main process must remain responsive for IPC and UI; the existing worker pool already handles long-running BSON work for sync, import, and verify.
- **Why default to Partial?** The user explicitly requested it. Partial is the typical desktop use case (browse a remote database without downloading everything); Full is for migration / backup scenarios where the user has explicitly decided they want a complete copy.
- **Cancellation is out of scope for v1.** The CLI replicate is also non-cancellable mid-stream. If we want a Cancel button in v2, we would need to thread an `AbortSignal` (or use the existing `context.cancellation` token) all the way down through `replicate()` and into every `retry()` call — significant scope. The dialog still lets the user dismiss when the run finishes.
- **Why not use `pickFolder` for `s3:` destinations?** `pickFolder` opens a native directory dialog, which only makes sense for local paths. For S3, the user types the `s3:bucket/prefix` string directly — same as the existing **Add database** flow.
- **Destination credentials live in the vault.** The dialog only lets the user pick from existing secrets. Generating a new encryption key from inside the dialog (the CLI's `--generate-key` behavior) is intentionally deferred — the user can create the key first via the Manage Secrets page, then pick it.
- **Open question (flag in the plan but do not block on it):** when the destination is an *existing* encrypted database, the worker has no way to know its encryption key from the source's credentials alone. The CLI prompts interactively. For v1 we accept that replicating to an existing encrypted destination requires the user to pre-register that destination as a database entry (with its `encryptionKey` set) — but the v1 dialog has no UX for picking an *existing* destination's secrets. Document this limitation in the **Configure** step's helper text: "To replicate to an existing encrypted database, register it on this page first and the replica will inherit its credentials." Actually implementing that inheritance would require Step 1b.3 to also try `resolveStorageCredentials(data.destPath)` first and fall back to the explicit `destEncryptionKeyId`/`destS3KeyId` only when the destination is not in `databases.json`. Decide during implementation whether to ship that fallback in v1 or defer.
