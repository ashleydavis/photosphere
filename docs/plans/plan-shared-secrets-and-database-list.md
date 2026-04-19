# Plan: Shared Secrets + Database List as Single Source of Truth

## Context

The Photosphere Electron app has a configured database list (currently stored inside `desktop.json`) and a per-database vault secrets system (stored as `db:{id}:*` in `~/.config/photosphere/vault/`). Three changes are needed:

1. **Move database list to its own file**: Databases are moved out of `desktop.json` into `~/.config/photosphere/databases.json`. `desktop.json` and `IDesktopConfig` are otherwise unchanged.

2. **Database list as single source of truth**: The "New database" and "Open database" sidebar buttons should go through the database list. Creating a database adds it to the list first; opening a database presents the list in a modal so the user picks from known databases.

3. **Shared secrets**: S3 credentials, encryption keys, and geocoding API keys should be stored as named shared secrets that multiple databases can reference. A new `/secrets` page manages these. The databases page (and new create-database modal) lets users assign a shared secret to each slot, with inline "create new" buttons.

---

## Critical Files

| File | Role |
|------|------|
| `packages/electron-defs/src/lib/electron-api.ts` | Shared types + `IElectronAPI` |
| `packages/node-utils/src/lib/desktop-config.ts` | Existing desktop config — `databases` field removed, nothing else changed |
| `packages/node-utils/src/lib/databases-config.ts` | **New file** — CRUD for `databases.json` (database entries + shared secrets metadata) |
| `apps/desktop/src/main.ts` | IPC handlers |
| `apps/desktop/src/preload.ts` | IPC bridge |
| `apps/desktop-frontend/src/lib/platform-provider-electron.tsx` | Platform impl |
| `packages/user-interface/src/context/platform-context.tsx` | `IPlatformContext` interface + frontend types |
| `packages/user-interface/src/pages/databases/databases-page.tsx` | Database CRUD page |
| `packages/user-interface/src/components/left-sidebar.tsx` | Sidebar buttons |
| `packages/user-interface/src/context/asset-database-source.tsx` | DB open/create helpers |
| `packages/user-interface/src/main.tsx` | Routes |

---

## Phase 1 — Shared Secrets Data Model

### 1a. New `ISharedSecretEntry` interface

Add to **`packages/electron-defs/src/lib/electron-api.ts`**:

```typescript
export interface ISharedSecretEntry {
    // 8-char random alphanumeric ID.
    id: string;
    // Human-readable display name chosen by the user.
    name: string;
    // The category of secret stored (e.g. 's3-credentials', 'encryption-key', 'api-key').
    type: string;
}
```

Also add the same interface to **`packages/user-interface/src/context/platform-context.tsx`** (frontend copy, same shape).

### 1b. Extend `IDatabaseEntry` with secret reference IDs

In **both** `electron-api.ts` and `platform-context.tsx`, add three optional fields to `IDatabaseEntry`:

```typescript
// References an ISharedSecretEntry.id for S3 credentials.
s3CredentialId?: string;
// References an ISharedSecretEntry.id for the encryption key pair.
encryptionKeyId?: string;
// References an ISharedSecretEntry.id for the geocoding API key.
geocodingKeyId?: string;
```

### 1c. New `databases-config.ts` and `IDatabasesConfig`

Create **`packages/node-utils/src/lib/databases-config.ts`** to own `~/.config/photosphere/databases.json`:

```typescript
interface IDatabasesConfig {
    databases: IDatabaseEntry[];
}
```

Functions to export: `loadDatabasesConfig()`, `saveDatabasesConfig()`, `getDatabases()`, `addDatabaseEntry()`, `updateDatabaseEntry()`, `removeDatabaseEntry()`.

Update **`packages/node-utils/src/lib/desktop-config.ts`**: remove the `databases` field from `IDesktopConfig` and remove all database-related functions (`getDatabases`, `addDatabaseEntry`, `updateDatabaseEntry`, `removeDatabaseEntry`). No other changes to this file.

### 1d. Vault storage for shared secrets

Shared secrets live entirely in the vault — no separate metadata registry. Each secret is stored as:
- **key**: `shared:{id}` (id = 8-char random alphanumeric generated client-side)
- **type**: the secret category string (e.g. `'s3-credentials'`)
- **value**: JSON encoding both the human-readable label and the actual credential fields, e.g. `{ "label": "My S3 bucket", "region": "us-east-1", ... }`

`ISharedSecretEntry` is the display-only view derived by splitting the vault entry:

```typescript
interface ISharedSecretEntry {
    id: string;    // extracted from the vault key "shared:{id}"
    name: string;  // the "label" field from the parsed value JSON
    type: string;  // vault's type field
}
```

---

## Phase 2 — IPC Layer

### 2a. New IPC handlers in `apps/desktop/src/main.ts`

Only one new IPC handler is required for secrets: none. All secrets CRUD is handled via the existing `vault-get`, `vault-set`, `vault-delete` IPC calls combined with the new `vault-list` call (see 2d). The only genuinely new handler is:

| IPC channel | Behaviour |
|-------------|-----------|
| `create-database-at-path` | Creates DB at known path (no picker) — runs the `create-database` task queue worker, then sends `database-opened` to renderer |

### 2b. Update `get-database-secrets` IPC handler

Instead of reading `db:{id}:s3` etc., resolve via the database entry's reference IDs:
- Load `IDatabaseEntry` for the given id from `getDatabases()`
- For each `s3CredentialId`, `encryptionKeyId`, `geocodingKeyId`, load `vault.get('shared:{refId}')` and parse
- Return assembled `IDatabaseSecrets`

### 2c. Update `remove-database-entry` IPC handler

Remove the vault deletions (`db:{id}:s3`, `db:{id}:geocoding`, `db:{id}:encryption`). Secrets are now independent and managed via the secrets page.

### 2d. Add `vault-list` IPC + `vaultList` to preload and ProxyVault

In **`apps/desktop/src/main.ts`**: add handler `vault-list` → returns `await vault.list()`.

In **`apps/desktop/src/preload.ts`** and **`IElectronAPI`**: add `vaultList(): Promise<IVaultSecret[]>`.

In **`apps/desktop-frontend/src/lib/proxy-vault.ts`**: add `list(): Promise<IVaultSecret[]>` that calls `electronAPI.vaultList()`.

Also add `createDatabaseAtPath(path: string): Promise<void>` to `IElectronAPI` and preload.

Remove `getDatabaseSecrets` and `setDatabaseSecrets` from `IElectronAPI` and the preload object (no longer called from the renderer; `get-database-secrets` remains in main.ts for internal import use only).

### 2e. Update `platform-provider-electron.tsx`

Implement secrets operations via `ProxyVault` directly — no new IPC calls:
- `listSecrets()`: calls `vault.list()`, filters entries with name starting with `shared:`, maps to `ISharedSecretEntry`
- `addSecret(entry, value)`: generates id client-side, calls `vault.set({ name: 'shared:{id}', type: entry.type, value: JSON.stringify({ label: entry.name, ...parsedValue }) })`
- `updateSecret(entry, value?)`: calls `vault.set(...)` with the same key
- `deleteSecret(id)`: calls `vault.delete('shared:{id}')`
- `getSecretValue(id)`: calls `vault.get('shared:{id}')`, returns the value string

Also add `createDatabaseAtPath`.

Remove `getDatabaseSecrets`, `setDatabaseSecrets`. `removeDatabaseEntry` now just calls `electronAPI.removeDatabaseEntry(id)` (no vault cleanup).

### 2f. Update `IPlatformContext` in `platform-context.tsx`

- Remove `getDatabaseSecrets`, `setDatabaseSecrets`
- Add `listSecrets`, `addSecret`, `updateSecret`, `deleteSecret`, `getSecretValue`, `createDatabaseAtPath`

---

## Phase 3 — Secrets Management Page

### New file: `packages/user-interface/src/pages/secrets/secrets-page.tsx`

Structure mirrors `databases-page.tsx`:
- Table with columns: Name, Type, Actions (Edit / Delete)
- **Add/Edit dialog** — when type is selected, shows type-specific fields:
  - `s3-credentials`: Endpoint (optional), Region, Access Key ID, Secret Access Key
  - `encryption-key`: Private Key PEM (textarea), Public Key PEM (textarea)
  - `api-key`: API Key (input)
- **Delete flow** (two-step):
  1. First confirmation: "Are you sure you want to delete '{name}'?"
  2. If the secret is used by any databases (found by scanning `s3CredentialId`, `encryptionKeyId`, `geocodingKeyId` across all `IDatabaseEntry` records), show a second confirmation listing the affected databases: "This secret is used by: [list]. Delete anyway?"

On save: call `platform.addSecret(entry, value)` or `platform.updateSecret(entry, value?)`.  
On delete (confirmed): call `platform.deleteSecret(id)`.

On edit, call `platform.getSecretValue(id)` to pre-populate the form.

### Route + sidebar link

In **`packages/user-interface/src/main.tsx`**: add `<Route path="/secrets" element={<SecretsPage />} />`.

In **`packages/user-interface/src/components/left-sidebar.tsx`**: add a "Manage Secrets" `NavLink` in (or near) the Databases collapsible section.

---

## Phase 4 — Updated Databases Page

In **`packages/user-interface/src/pages/databases/databases-page.tsx`**:

Replace the three AccordionGroups (S3 / Encryption / Geocoding inline fields) with three **secret selector rows**, one per type. Each row:
- A `Select` dropdown populated from the filtered list of shared secrets of the matching type  
- A "+ New" button that opens a quick-create dialog (same form as the secrets page add-dialog, pre-filtered to that type). The name field is **pre-populated** with the database name (or the database id if the name is blank) so the user can accept or edit it before saving. On save it creates the secret via `platform.addSecret()` and auto-selects it in the dropdown.

State changes:
- Remove `IDatabaseFormState` fields: `s3Endpoint`, `s3Region`, `s3AccessKeyId`, `s3SecretAccessKey`, `privateKeyPem`, `publicKeyPem`, `geocodingApiKey`
- Add: `s3CredentialId: string | undefined`, `encryptionKeyId: string | undefined`, `geocodingKeyId: string | undefined`

`handleSave` now calls only `platform.addDatabase()` / `platform.updateDatabase()` with the reference IDs. No `setDatabaseSecrets` call.

`openEditDialog` loads only the `IDatabaseEntry` (already has reference IDs). No `getDatabaseSecrets` call.

---

## Phase 5 — Open / Create Database Modals

### New file: `packages/user-interface/src/components/open-database-modal.tsx`

Props: `open: boolean`, `onClose(): void`

Content:
- Loads `platform.getDatabases()` on open
- Table/list showing each database (name, path, whether it's currently open)
- Clicking a row selects it; "Open" button calls `openDatabase(entry.path)` from `useAssetDatabase()` then closes modal
- "Cancel" button closes modal

### New file: `packages/user-interface/src/components/create-database-modal.tsx`

Props: `open: boolean`, `onClose(): void`

Content:
- Name (required), Description fields
- Path field + Browse button (calls `platform.pickFolder()`)
- Three secret selector rows (same pattern as the updated databases page) — `s3-credentials`, `encryption-key`, `api-key`. When the "+ New" button is used, the secret name defaults to the database name entered above (editable before save).
- "Create" button:
  1. Calls `platform.addDatabase({ name, description, path, s3CredentialId, encryptionKeyId, geocodingKeyId })`
  2. Calls `platform.createDatabaseAtPath(path)` — creates the DB on disk and triggers `database-opened` event
  3. Closes modal (the `database-opened` event will load the new DB via `AssetDatabaseProvider`'s existing listener)
- "Cancel" button

### Wire up sidebar

In **`packages/user-interface/src/components/left-sidebar.tsx`**:
- Add local state: `openModalOpen: boolean`, `createModalOpen: boolean`
- "New database" list item: sets `createModalOpen = true` (no longer calls `selectAndCreateDatabase()`)
- "Open database" list item: sets `openModalOpen = true` (no longer calls `selectAndOpenDatabase()`)
- Render `<OpenDatabaseModal open={openModalOpen} onClose={() => setOpenModalOpen(false)} />` and `<CreateDatabaseModal open={createModalOpen} onClose={() => setCreateModalOpen(false)} />` at the bottom of the sidebar component

The existing `selectAndOpenDatabase()` and `selectAndCreateDatabase()` methods on `IAssetDatabase` can remain (they may still be triggered from Electron menu items), but the sidebar no longer uses them.

---

## Verification

1. **Secrets page**: Navigate to `/secrets`. Add an S3 credential, an encryption key, a geocoding key. Verify they appear in the list. Edit one, delete one (confirm two-step flow when a database references it).

2. **Database create flow**: Click "New database" in sidebar → modal appears → fill name, path, assign a shared secret → click Create → modal closes → new database appears open in gallery.

3. **Database open flow**: Click "Open database" in sidebar → modal lists configured databases → click one → it opens in the gallery.

4. **Database edit in Databases page**: Navigate to `/databases` → edit an entry → dropdown shows shared secrets of the right type → change assignment → save → verify import uses the right secret.

5. **Delete secret with database references**: Create a secret, assign it to a database. Go to secrets page, delete that secret → first confirmation → second confirmation listing the database → confirm → secret is gone and database no longer has the reference.

6. **TypeScript compile check**: `bun run compile` passes with no errors.
