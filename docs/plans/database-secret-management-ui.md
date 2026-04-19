# Plan: Database & Secret Management UI Overhaul

## Context
The existing "New Database" and "Open Database" modals lack storage-type selection (Filesystem vs S3), have primitive inline secret dropdowns, and the sidebar shows all databases rather than a recent-first list. The user has defined a complete rework of how databases are created, added, and browsed.

---

## Final Design

### Menu / Sidebar / "No database loaded" actions
| Action | Fires | Opens |
|---|---|---|
| New Database | `new-database` menu-action | CreateDatabaseModal (unchanged wiring) |
| Open Database | `open-database` menu-action | OpenDatabaseModal (list view) |

### OpenDatabaseModal (list view)
- Shows all configured databases in a table (Name, Path, Status)
- Click row to select; "Open" button opens it
- "Add database" button → AddDatabaseModal (inline, managed inside this modal)
- "Manage databases" button → navigate to `/databases`, close modal
- "Cancel" button

### CreateDatabaseModal (new database — Filesystem or S3)
Fields:
1. Name, Description
2. Type: `File system | S3` (Select)
3. **If Filesystem**: Path [text] + [Browse] (native folder picker — OS natively supports creating new folders)
4. **If S3**: S3 Credentials [select-secret button, type `s3-credentials`] then Path [text] + [Browse S3] (enabled only after credentials chosen)
5. Encrypted: [toggle] — shows Encryption Key selector when on
6. If Encrypted: Encryption Key [select-secret button, type `encryption-key`]
7. Geocoding API Key [select-secret button, type `api-key`] (always optional)

On submit:
1. `platform.addDatabase(...)` — registers the new database in `databases.json`
2. `platform.createDatabaseAtPath(path)` — initialises the database (Filesystem or S3; backend routes by path prefix)
3. `openDatabase(path)` — makes it the currently loaded database

### AddDatabaseModal (register existing database)
Same fields as CreateDatabaseModal, with these differences:
- Title is "Add Database"
- **Filesystem**: Browse uses native folder picker (picks existing folder)
- **S3**: S3 Credentials selector appears first; Browse S3 button opens `S3BrowserModal` (same as CreateDatabaseModal)

On submit:
1. `platform.addDatabase(...)` — registers the database in `databases.json`
2. `openDatabase(path)` — makes it the currently loaded database (no `createDatabaseAtPath` — database already exists)

### SelectSecretModal
- Props: `open`, `secretType: string`, `onClose`, `onSelect: (secret: ISharedSecretEntry) => void`
- Lists all secrets of `secretType` in a table
- [Select] button per row → calls `onSelect`, closes
- [Create new] button → opens `CreateSecretDialog` inline; on save auto-selects the new secret
- [Cancel] button

### S3BrowserModal
- Props: `open`, `credentialId: string`, `onClose`, `onSelect: (path: string) => void`
- State: `bucket: string`, `prefix: string`, `entries: string[]`
- Bucket text input at top (loads root listing on change)
- Breadcrumb trail for current prefix
- Directory listing (calls `platform.listS3Dirs(credentialId, bucket, prefix)`)
- Click entry to navigate deeper
- [Select this location] → calls `onSelect('s3:' + bucket + ':/' + prefix)`
- [Cancel]

### Left sidebar — recent databases
- Shows the most recent **5** databases (ordered by last-opened, most recent first)
- Click opens that database immediately
- Loaded from `platform.getRecentDatabases()`
- Recency is tracked by a `recentDatabaseIds: string[]` list in `databases.json` (top of list = most recent, trimmed to 5)

### "No database loaded" screen
- Buttons: "New database" → CreateDatabaseModal, "Add database" → AddDatabaseModal
- Below buttons: list of recent databases (top-5 from `getRecentDatabases()`, click to open directly — no need for an "Open database" button since the list is right there)

---

## Files to create

| File | Purpose |
|---|---|
| `packages/user-interface/src/components/add-database-modal.tsx` | AddDatabaseModal component |
| `packages/user-interface/src/components/select-secret-modal.tsx` | SelectSecretModal component |
| `packages/user-interface/src/components/s3-browser-modal.tsx` | S3BrowserModal component |
| `packages/user-interface/src/components/create-secret-dialog.tsx` | Renamed from `secret-quick-create-dialog.tsx` — all callers updated |

---

## Files to modify

### `packages/electron-defs/src/lib/electron-api.ts`
- Add to `IElectronAPI`:
  ```typescript
  listS3Dirs(credentialId: string, bucket: string, prefix: string): Promise<string[]>;
  getRecentDatabases(): Promise<IDatabaseEntry[]>;
  ```

### `packages/node-utils/src/lib/databases-config.ts`
- Add `recentDatabaseIds: string[]` to `IDatabasesConfig`
- Add `getRecentDatabases(): Promise<IDatabaseEntry[]>` — looks up IDs in order, returns matching entries
- Add `markDatabaseOpenedByPath(path: string): Promise<void>` — finds entry by path, moves its ID to front of `recentDatabaseIds`, trims to 5, saves

### `packages/node-utils/src/index.ts`
- Export `getRecentDatabases`, `markDatabaseOpenedByPath`

### `packages/user-interface/src/context/platform-context.tsx`
- Add to `IPlatformContext`:
  ```typescript
  getRecentDatabases(): Promise<IDatabaseEntry[]>;
  listS3Dirs(credentialId: string, bucket: string, prefix: string): Promise<string[]>;
  ```

### `packages/user-interface/src/components/create-database-modal.tsx`
Full rewrite of form:
- `ICreateDatabaseFormState` gains: `storageType: 'filesystem' | 's3'`, `encrypted: boolean`
- Secret selectors replaced with `SelectSecretModal` trigger buttons
- S3 Credentials selector shown first when type === 's3' (needed before Browse S3)
- `S3BrowserModal` rendered inline, opened by Browse button when type === 's3'
- Browse button calls `platform.pickFolder()` when type === 'filesystem'
- Encrypted toggle shows/hides Encryption Key selector

### `packages/user-interface/src/pages/secrets/secrets-page.tsx`
- Page title: "Manage Secrets"

### `packages/user-interface/src/pages/databases/databases-page.tsx`
- Page title: "Manage Databases"
- Add "New database" button → renders `<CreateDatabaseModal>` internally
- Add "Add database" button → renders `<AddDatabaseModal>` internally
- Both buttons sit in the page header alongside the existing controls

### `packages/user-interface/src/components/open-database-modal.tsx`
- Keep existing table list
- Change empty-state message to: "No databases configured yet."
- Replace "Browse..." button with "Add database" button → renders `<AddDatabaseModal>` internally
- Add "Manage databases" button → `useNavigate()` to `/databases`, then `onClose()`
- Remove the old handleBrowse / addDatabase logic added previously

### `packages/user-interface/src/components/no-database-loaded.tsx`
- Replace existing buttons with "New database" → CreateDatabaseModal and "Add database" → AddDatabaseModal
- Load recent databases on mount via `platform.getRecentDatabases()`
- Render clickable list below the buttons (Name or path, click calls `openDatabase`)

### `packages/user-interface/src/components/left-sidebar.tsx`
- Replace `dbs.map(...)` section in the Databases collapsible with recent databases (top 5 from `platform.getRecentDatabases()`)
- Keep "Manage Databases" and "Manage Secrets" nav links
- Remove delete buttons from sidebar entries (that belongs on the Manage page)

### `apps/desktop/src/main.ts`
- Add IPC handler `list-s3-dirs`:
  1. Load secret from vault by `shared:{credentialId}`
  2. Parse JSON to get `accessKeyId`, `secretAccessKey`, `region`, `endpoint`
  3. Create `CloudStorage` with those credentials and bucket
  4. Call `storage.listDirs('/' + prefix, 100)`
  5. Return the resulting `names` array
- Add IPC handler `get-recent-databases`: calls `getRecentDatabases()` from node-utils
- In `notify-database-opened` handler, call `markDatabaseOpenedByPath(databasePath)` after updating the entry

### `apps/desktop/src/preload.ts`
- Add `listS3Dirs(credentialId, bucket, prefix)` → `ipcRenderer.invoke('list-s3-dirs', ...)`
- Add `getRecentDatabases()` → `ipcRenderer.invoke('get-recent-databases')`

### `apps/desktop-frontend/src/lib/platform-provider-electron.tsx`
- Implement `getRecentDatabases()`: calls `electronAPI.getRecentDatabases()`
- Implement `listS3Dirs(credentialId, bucket, prefix)`: calls `electronAPI.listS3Dirs(...)`

### `apps/dev-frontend/src/lib/platform-provider-web.tsx`
- `getRecentDatabases`: returns `[]`
- `listS3Dirs`: returns `[]`

---

## Reuse
- `SecretQuickCreateDialog` — renamed to `CreateSecretDialog`, reused inside `SelectSecretModal` for inline secret creation
- `platform.pickFolder()` — reused for filesystem Browse in both Create and Add modals
- `platform.listSecrets()` — used in `SelectSecretModal` to load the filtered secret list
- `CloudStorage.listDirs()` from `packages/storage/src/lib/cloud-storage.ts` — used in `list-s3-dirs` IPC handler
- `loadDatabasesConfig` / `saveDatabasesConfig` from `databases-config.ts` — reused for recency updates

---

## Verification
1. Run `bun run compile` — all packages must pass
2. Launch desktop app (`bun run dev` from root)
3. **New database (filesystem)**: File > New Database → fill Name, Type=Filesystem, Browse for folder → Create → gallery loads
4. **New database (S3)**: File > New Database → Type=S3, select S3 credentials, Browse S3 → navigate bucket → Create
5. **Add database**: File > Open Database → "Add database" → fill in path of existing db → Add → opens
6. **Open database**: File > Open Database → click existing entry → Open → gallery loads
7. **Manage databases**: File > Open Database → "Manage databases" → /databases page opens, has New/Add buttons
8. **Select secret**: In Create/Add modal, click secret button → SelectSecretModal opens → select or create
9. **Sidebar recent**: Open 3+ databases → sidebar shows them in most-recently-opened order, max 5
10. **No DB screen**: Close database → "No database loaded" screen shows New/Add buttons and recent list
