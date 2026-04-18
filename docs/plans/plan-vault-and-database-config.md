# Plan: Vault-backed Secrets & Database Configuration Management

## Context

The app currently stores S3 credentials and the Google geocoding API key in a plaintext INI file (`~/.config/photosphere/photosphere.conf`) and encryption keys as `.key` PEM files in `~/.config/photosphere/keys/`. The Electron desktop app tracks databases as a flat `recentDatabases: string[]` list with no ability to associate per-database credentials.

This change:
1. Routes all secrets through the already-built `packages/vault` (plaintext vault under `~/.config/photosphere/vault/`).
2. Replaces `recentDatabases: string[]` with a structured `databases: IDatabaseEntry[]` list, each entry linking to vault-stored secrets.
3. Adds a new Electron "Databases" page for full CRUD management (name, description, path, S3 creds, encryption key, geocoding key).

No backward compatibility required.

Keep all code changes minimal — only edit the specific lines needed for each feature. Do not reformat, restructure, or clean up surrounding code.

Add or update unit tests for all new and modified code. Update existing tests where behaviour changes (e.g. CLI config functions now using vault instead of INI file).

Update documentation (README files, wiki pages, inline comments) where behaviour changes — particularly around secrets storage, the new vault commands, and the databases configuration page.

---

## Vault Key Naming Scheme

The vault is stored at `~/.config/photosphere/vault/` — Photosphere-specific, so no prefix needed.

| Secret | Vault key |
|---|---|
| CLI S3 credentials | `cli:s3` (JSON `IS3Credentials`) |
| CLI geocoding API key | `cli:geocoding` (plain string) |
| CLI encryption key pair | `cli:encryption:{keyName}` (JSON `IEncryptionKeyPair`) |
| Per-DB S3 credentials | `db:{id}:s3` (JSON `IS3Credentials`) |
| Per-DB geocoding key | `db:{id}:geocoding` (plain string) |
| Per-DB encryption key pair | `db:{id}:encryption` (JSON `IEncryptionKeyPair`) |

---

## New Types (to be added to `packages/electron-defs/src/lib/electron-api.ts`)

```typescript
// S3 credentials (duplicated from storage package for IPC / frontend use)
interface IS3Credentials { region, accessKeyId, secretAccessKey, endpoint? }

// Private+public PEM key pair stored in vault
interface IEncryptionKeyPair { privateKeyPem: string; publicKeyPem: string; }

// All secrets for a database (all optional — missing means not configured)
interface IDatabaseSecrets { s3Credentials?, encryptionKeyPair?, geocodingApiKey? }

// Non-sensitive per-database config stored in desktop.json
// id is an 8-character random alphanumeric string (e.g. "a3k9mz7x")
interface IDatabaseEntry { id: string; name: string; description: string; path: string; origin?: string; }
```

Mirror these types (same shapes, no import) in `packages/user-interface/src/context/platform-context.tsx` to keep the frontend independent of Node.js packages.

---

## Vault Access Pattern

All consumers call `getVault("plaintext")` exactly as the existing API intends. The `PlaintextVault` default directory is changed from `~/.config/vault/` to `~/.config/photosphere/vault/`.

---

## Files to Create / Modify

### 1. `packages/vault/src/lib/plaintext-vault.ts`
- Change `DEFAULT_VAULT_DIR` from `~/.config/vault` to `~/.config/photosphere/vault`.

### 2. `packages/electron-defs/src/lib/electron-api.ts`
- Add `IS3Credentials`, `IEncryptionKeyPair`, `IDatabaseSecrets`, `IDatabaseEntry` interfaces.
- Add to `IElectronAPI`:
  - `getDatabases(): Promise<IDatabaseEntry[]>`
  - `addDatabase(entry: Omit<IDatabaseEntry, 'id'>): Promise<IDatabaseEntry>`
  - `updateDatabase(entry: IDatabaseEntry): Promise<void>`
  - `removeDatabaseEntry(id: string): Promise<void>`
  - `getDatabaseSecrets(id: string): Promise<IDatabaseSecrets>`
  - `setDatabaseSecrets(id: string, secrets: IDatabaseSecrets): Promise<void>`
  - `pickFolder(): Promise<string | undefined>` (directory picker that returns path only)

### 3. `packages/storage/src/lib/key-utils.ts`
- Add `loadEncryptionKeysFromPem(privateKeyPem: string, publicKeyPem: string): Promise<IStorageOptions>`.
  - Creates `KeyObject` from PEM strings (using Node `crypto`) without touching the filesystem.

### 4. `packages/storage/src/lib/storage-factory.ts` (and `IStorageDescriptor`)
- Extend `IStorageDescriptor` with optional `encryptionKeyPems?: IEncryptionKeyPair[]`.
- Update `packages/storage/src/index.ts` to export the new function and updated types.

### 5. `packages/node-utils/src/lib/desktop-config.ts`
- Import `IDatabaseEntry` from `electron-defs` (add `electron-defs: workspace:*` to `packages/node-utils/package.json`).
- In `IDesktopConfig`: replace `recentDatabases?: string[]` and `lastDatabase?: string` with `databases?: IDatabaseEntry[]`.
- Remove: `addRecentDatabase`, `removeRecentDatabase`, `clearLastDatabase`.
- Add: `getDatabases()`, `addDatabaseEntry(entry)`, `updateDatabaseEntry(entry)`, `removeDatabaseEntry(id)`.
- `loadDesktopConfig` default returns `{ databases: [] }`.
- Export new functions from `packages/node-utils/src/index.ts`.

### 6. `apps/desktop/package.json`
- Add `"vault": "workspace:*"` to `dependencies`.
- Also add `"storage": "workspace:*"` to `dependencies` (currently only available transitively).

### 7. `apps/desktop/src/main.ts`
- Import `getVault` from `vault`; import `loadEncryptionKeysFromPem` from `storage`.
- Call `getVault("plaintext")` to get the vault instance — used by all IPC handlers.
- Replace calls to `addRecentDatabase`/`removeRecentDatabase`/`clearLastDatabase` with new `node-utils` functions.
- Add IPC handlers (via `ipcMain.handle`):
  - `get-databases` → `getDatabases()`
  - `add-database` → generates an 8-character random alphanumeric id, reads origin from `.db/config.json` using `loadDatabaseConfig`, then `addDatabaseEntry`
  - `update-database` → `updateDatabaseEntry`
  - `remove-database-entry` → also deletes associated vault secrets, then `removeDatabaseEntry`
  - `get-database-secrets` → reads vault keys for the given database id
  - `set-database-secrets` → writes vault keys for the given database id
  - `pick-folder` → `showDirectoryPicker` returning only the path
- Update `startImportWithPaths`:
  - Find the `IDatabaseEntry` matching `currentDatabasePath`.
  - Load `IDatabaseSecrets` from vault.
  - Pass `s3Config` and (if encryption key present) `encryptionKeyPems` in the storage descriptor.
- Update `notifyDatabaseOpened` handler: if the opened path is not in the database list, auto-add it (name = basename, empty description, read origin).

### 8. `apps/desktop/src/preload.ts`
- Expose the 7 new IPC methods via `contextBridge`.

### 9. `apps/desktop-frontend/src/lib/platform-provider-electron.tsx`
- Implement the 7 new platform context methods by delegating to `electronAPI.*`.

### 10. `packages/user-interface/src/context/platform-context.tsx`
- Add `IS3Credentials`, `IEncryptionKeyPair`, `IDatabaseSecrets`, `IDatabaseEntry` (matching `electron-defs` shapes but defined locally).
- Add to `IPlatformContext`:
  - `getDatabases`, `addDatabase`, `updateDatabase`, `removeDatabaseEntry`, `getDatabaseSecrets`, `setDatabaseSecrets`, `pickFolder`

### 11. `packages/user-interface/src/context/app-context.tsx`
- Change `dbs: string[]` → `dbs: IDatabaseEntry[]`.
- `load()`: call `platform.getDatabases()` instead of `config.get('recentDatabases')`.
- `removeDatabase(id: string)`: call `platform.removeDatabaseEntry(id)` instead of `config.remove(...)`.

### 12. `packages/user-interface/src/components/left-sidebar.tsx`
- Update the "Databases" collapsible section:
  - Iterate `dbs: IDatabaseEntry[]` using `entry.id` as key.
  - Show `entry.name` (or path basename fallback) in `ListItemContent`.
  - `onClick`: `openDatabase(entry.path)`.
  - Active detection: `entry.path === databasePath`.
  - Remove button: call `removeDatabase(entry.id)`.
- Add a "Manage Databases" `NavLink` to `/databases` near the top of the list (after "Open database").

### 13. `packages/user-interface/src/main.tsx`
- Add route: `<Route path="/databases" element={<DatabasesPage />} />`.
- Import `DatabasesPage` from `./pages/databases/databases-page`.

### 14. `packages/user-interface/src/pages/databases/databases-page.tsx` (**new file**)
Full CRUD UI using MUI Joy:

**List view:**
- Table/List of `IDatabaseEntry[]` loaded via `platform.getDatabases()`.
- Columns: Name, Description, Path, Origin.
- Row actions: Edit (pencil icon), Remove (remove icon with confirmation dialog).
- Top-right "Add Database" button.

**Add/Edit Dialog (`Modal > ModalDialog`):**
- Fields: Name (`Input`), Description (`Input`), Path (`Input` + Browse button that calls `platform.pickFolder()`).
- Three collapsible `AccordionGroup` sections for secrets:
  - **S3 Credentials**: Endpoint (optional), Region, Access Key ID, Secret Access Key (masked).
  - **Encryption Key**: Private Key PEM (`Textarea`), Public Key PEM (`Textarea`).
  - **Geocoding**: API Key (`Input`).
- On save: call `platform.addDatabase` or `platform.updateDatabase`, then `platform.setDatabaseSecrets`.
- On load (edit): call `platform.getDatabaseSecrets(id)` to populate secrets fields.

**Remove Confirmation Dialog**: confirm before calling `platform.removeDatabaseEntry(id)`. Wording must make clear this only removes the entry from the list — it does not delete any files on disk.

### 15. `apps/cli/src/lib/config.ts`
- Add `vault: workspace:*` to `apps/cli/package.json`.
- Replace all INI file storage with vault calls using `getVault("plaintext")`:
  - `getS3Config()`: reads `cli:s3` from vault, parses JSON.
  - `configureS3()`: writes JSON to `cli:s3` in vault.
  - `getGoogleApiKey()`: reads `cli:geocoding` from vault (env var still takes precedence).
  - `configureGoogleApiKey()`, `setGoogleApiKey()`, `removeGoogleApiKey()`: write/delete `cli:geocoding` in vault.
  - `resetGoogleApiKeyDeclined()`: clears the `googleApiKeyDeclined` flag from the CLI config JSON file (kept in `~/.config/photosphere/cli.json`, separate from secrets).
  - `clearConfig()`: delete vault secrets `cli:s3` and `cli:geocoding`; also clear the CLI config JSON file.
- Remove: `loadConfig`, `saveConfig`, `parseIniConfig`, `formatIniConfig`, `IConfig`.

### 16. `apps/cli/src/lib/init-cmd.ts`
- Replace file-based encryption key handling with vault:
  - `getAvailableKeys()`: list vault secrets of type `encryption-key` (keys matching `cli:encryption:*`).
  - `selectEncryptionKey()`: prompts user to pick from vault-stored key names.
  - `promptForEncryption()` "generate" branch: prompts for a key name, generates RSA-4096 key pair in memory, stores as `IEncryptionKeyPair` JSON under `cli:encryption:{keyName}` in vault.
  - `promptForEncryption()` "existing" branch: picks from vault key list.
  - `resolveKeyPath()` / `resolveKeyPaths()`: replaced by vault lookups — accepts a key name, returns the `IEncryptionKeyPair` from vault.
  - `loadDatabase()` / `createDatabase()`: instead of passing `encryptionKeyPaths` to `loadEncryptionKeys`, retrieve the PEM pair from vault and call `loadEncryptionKeysFromPem`.
- Remove: `resolveKeyPath`, `resolveKeyPaths`, `promptForKeyGenerationPath` (merged into `promptForEncryption`).
- Remove `~/.config/photosphere/keys/` directory usage from code entirely.
- **Never delete `~/.config/photosphere/keys/` or any files within it.** Existing key files on disk are left untouched — users migrate them manually via `psi vault import`.

### 17. `apps/cli/src/cmd/vault.ts` (**new file**)

New `psi vault` subcommand group with the following subcommands:

- **`psi vault add`**  
  Interactively adds a new secret. Prompts for name, type, and value. Errors if the name already exists.

- **`psi vault list`**  
  Lists all secrets in the vault. Shows name and type for each; masks the value.

- **`psi vault view <name>`**  
  Shows the full value of a named secret. For JSON secrets (S3 creds, encryption keys) pretty-prints the fields. Prompts for confirmation before revealing sensitive values.

- **`psi vault edit <name>`**  
  Loads the existing secret and re-prompts for each field with the current value pre-populated as the initial value. The user can accept (press enter) or overwrite each field. Saves the updated secret when done.

- **`psi vault delete <name>`**  
  Deletes a named secret from the vault after confirmation.

- **`psi vault import`**  
  Imports an existing `.key` / `.key.pub` PEM key pair from disk into the vault:
  1. Prompts for the path to the private key file (`.key`).
  2. Derives the public key path as `{keyfile}.pub` (or prompts if not found).
  3. Prompts for a vault name (defaults to the filename without extension).
  4. Stores as `cli:encryption:{keyName}` in the vault.
  5. Confirms success and shows the vault key name.

Register `vault` command in the CLI's root command file (`apps/cli/src/examples.ts` or wherever commands are registered).

---

## Worker Key-Loading Update

In the worker process (`apps/desktop/src/worker.ts` or wherever it calls `loadEncryptionKeys`):
- Check `storageDescriptor.encryptionKeyPems`. If set (and `encryptionKeyPaths` is empty), call `loadEncryptionKeysFromPem` instead of `loadEncryptionKeys`.

---

## Verification

1. **TypeScript compile**: `bun run compile` from root — no errors.
2. **Tests**: `bun run test` from root — all pass.
3. **CLI vault integration**:
   - Run `psi config` → verify S3 creds write to `~/.config/photosphere/vault/`.
   - Confirm `~/.config/photosphere/photosphere.conf` is no longer used.
4. **Electron databases page**:
   - Launch Electron app, navigate to Databases via sidebar.
   - Add a local FS database, verify it appears in sidebar.
   - Edit name/description, verify persisted.
   - Add S3 credentials, verify they appear in `~/.config/photosphere/vault/`.
   - Remove database entry, verify vault secrets also deleted.
5. **Import with vault secrets**:
   - Configure a database with encryption key pair and S3 creds via Databases page.
   - Import assets into that database, verify encryption works end-to-end.
6. **Origin display**: Open a database with an origin in `.db/config.json`; verify it shows in the Databases page.
