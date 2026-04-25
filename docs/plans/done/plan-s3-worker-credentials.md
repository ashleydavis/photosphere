# Plan: Consistent Credential Resolution for CLI and Electron Workers

## Issues to Resolve Before Implementing

### Issue 1 — [x] Duplicate section number 7
The plan has two `### 7.` headings: "Remove `shared:` prefix" and "Update smoke test seed data". The second should be `### 8.`, shifting all later steps. The body has 9 logical steps but the last heading reads 8.

**Fix:** Renumber the second `### 7.` and all subsequent headings.

---

### Issue 2 — [x] `shared:` prefix scope is overstated
Current Problems section 3 says the bug is at `init-cmd.ts:393`. Step 7 says to remove it "from all vault lookups." But `desktop/main.ts` and both `lan-share` files already access vault secrets without the `shared:` prefix — the bug is isolated to `init-cmd.ts` only.

**Fix:** Change the step 7 prose from "Remove `"shared:" +` from all vault lookups" to "Remove `"shared:" +` from vault lookups in `init-cmd.ts`."

---

### Issue 3 — [x] `dbDir` vs `databasePath` inconsistency within the plan
The "What is passed to workers" section uses `databasePath`, but `IDatabaseDescriptor` defines the field as `dbDir` (carried over from `IStorageDescriptor`). The plan also says *"Workers detect whether a database is S3-backed by checking if `databasePath.startsWith('s3:')`"* — which would be `dbDir` in the actual interface.

**Fix:** Decide on one name. Renaming `dbDir` to `databasePath` in `IDatabaseDescriptor` matches the worker message field name and the plan's own prose, and is more readable.

---

### Issue 4 — [x] Step 3 understates the semantic change
The plan frames step 3 as "Move and rename `IStorageDescriptor` → `IDatabaseDescriptor`", but this is a fundamental semantic change:
- Old: `encryptionKeyPems: IEncryptionKeyPem[]` — already-resolved PEM data passed in
- New: `encryptionKey?: string` — an unresolved name or path that workers look up themselves

This is the core of the "workers self-resolve" principle, not just a rename.

**Fix:** Add a sentence to step 3 explicitly calling out that `encryptionKeyPems` is removed (workers no longer receive resolved PEMs) and `encryptionKey` is added as an unresolved identifier that workers pass to `resolveStorageCredentials`.

---

### Issue 5 — [x] `validateEncryptionKey` is redundant with `resolveStorageCredentials`
Step 5 introduces a CLI-level `validateEncryptionKey` that does the same file/vault existence check as `resolveStorageCredentials` does internally for the `-k` case. The only distinction is it runs early to fail fast before any workers are spawned.

**Fix:** Either remove `validateEncryptionKey` and call `resolveStorageCredentials` early in the CLI command (discarding the result), or add a note to the plan explaining explicitly that the duplication is intentional for fail-fast UX, so an implementer doesn't collapse the two.

---

### Issue 6 — [x] `smoke-tests-lan-share.sh` table entry needs more detail (confirmed)
The critical files table lists `apps/cli/smoke-tests-lan-share.sh` with just "Field rename". Confirmed: line 212 hardcodes JSON with `s3CredentialId` and `encryptionKeyId` directly in a `seed_databases_config` call.

**Fix:** Update the table note to: "Update hardcoded JSON in `seed_databases_config` call: `s3CredentialId` → `s3Key`, `encryptionKeyId` → `encryptionKey`."

---

### Issue 7 — [x] `ICredentialOptions` is a single-field interface — deliberate?
`ICredentialOptions` wraps a single `encryptionKey?: string`. Per codebase style this is fine, but if no second field will ever be added (there is no CLI flag for geocoding, for example), a plain optional second parameter to `resolveStorageCredentials` would be simpler.

**Fix:** Confirm this is intentional (kept as an interface for extensibility) or simplify to a plain parameter. Either way, make the decision explicit in the plan.

---

### Issue 8 — [x] Vault must not be accessed unless actually needed
`resolveStorageCredentials` resolves all three credential types (S3, encryption key, geocoding) in one call. But:
- Many workers need only a subset of these — and for a local unencrypted database with no geocoding, the answer is zero.
- The vault should never be opened unless a credential is genuinely required — vault access may prompt for a password or have other side effects.
- The plan already states S3 credentials are only needed when `databasePath.startsWith('s3:')`, but the function's resolution logic doesn't make this guard explicit.

**Fix:** Add conditional guards to the resolution logic:
- Skip S3 vault lookup entirely if `databasePath` does not start with `s3:`.

Resolved by Step 2's data-driven guards (path prefix, env vars, databases.json entry check) — no caller flags or split functions needed.

---

## The Intended Design

`databases.json` holds a list of registered databases. Each entry has a `path` and optional vault encryptionKey name fields. These store the vault encryptionKey name directly — nothing more. No prefix manipulation.

The fields in `IDatabaseEntry` should be renamed to reflect this:
- `s3CredentialId` → `s3Key`
- `encryptionKeyId` → `encryptionKey`
- `geocodingKeyId` → `geocodingKey`

(The old names ending in `Id` were a hangover from when they stored just the ID portion of a `shared:{id}` vault encryptionKey.)

**Credential resolution priority, applied the same way everywhere:**

| Credential | Priority order |
|---|---|
| S3 | vault via `s3Key` → env vars (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, `AWS_ENDPOINT`) |
| Encryption encryptionKey | `-k` CLI flag (file path or vault name) → vault via `encryptionKey` → `PSI_ENCRYPTION_KEY` env var (file path or vault name) |
| Geocoding | vault via `geocodingKey` → `GOOGLE_API_KEY` env var |

**Rules:**
- The CLI can work with a bare path (not in databases.json), falling back to env vars for credentials.
- The CLI can also work with a registered path or name from databases.json, resolving credentials from the vault.
- Electron works by path, but that path is always one registered in the database list — it never opens arbitrary unregistered paths.
- Secrets are never passed through IPC or worker messages. Workers resolve credentials themselves using the database path + vault + env vars.
- The `-k` flag accepts either a file path (reads PEM directly) or a vault secret name.

**What is passed to workers:**

Workers receive only what they cannot derive themselves:
- `databasePath` — the path to the database (used to look up credentials from databases.json + vault)
- `encryptionKey` — optional, only present when the user passed `-k` on the CLI (a file path or vault secret name)

Workers do **not** receive S3 credentials, encryption encryptionKey PEMs, or geocoding encryptionKeys. They resolve all of these themselves via env vars and vault.

Workers detect whether a database is S3-backed by checking if `databasePath.startsWith('s3:')`. `createStorage()` uses the same check internally — S3 credentials are only needed and looked up when the path is an S3 path.

---

## Current Problems

### 1. Workers that hardcode `undefined` for S3 credentials

These call `createStorage(path, undefined, undefined)` — works for local FS, silently fails for S3:

| Worker | Location |
|--------|----------|
| `sync-database.worker.ts` | lines 32, 51 |
| `prefetch-database.worker.ts` | lines 41, 55 |
| `load-assets.worker.ts` | line 33 |
| `create-database.worker.ts` | line 26 |
| `createLazyDatabaseStorage()` in `media-file-database.ts` | lines 585, 597 |

### 2. Workers that receive secrets via message payload

These receive `encryptionKeyPems` pre-resolved in `storageDescriptor` and `s3Config` as raw credentials:

- `verify.worker.ts`
- `check.worker.ts`
- `import-assets.worker.ts`
- `hash-file.worker.ts`
- `upload-asset.worker.ts`

This violates the rule that workers resolve credentials themselves. These should receive only the database path (and optionally a encryptionKey name/path from `-k`) and look up everything else.

### 3. `shared:` prefix bug in CLI

`init-cmd.ts:393` prepends `"shared:"` to credential IDs before vault lookup. The credential ID in databases.json already is the vault encryptionKey name. This prefix is wrong and breaks cross-app compatibility. Remove it everywhere.

---

## Proposed Changes

### 1. Add `vault` dependency to `api`

**File:** `packages/api/package.json`

Add `"vault": "workspace:*"` to `dependencies`.

### 2. Create `resolveStorageCredentials` utility

**New file:** `packages/api/src/lib/resolve-storage-credentials.ts`

Single function all workers and CLI commands use:

```typescript
export interface IResolvedStorageCredentials {
    s3Config?: IS3Credentials;
    encryptionKeyPems: IEncryptionKeyPem[];
    googleApiKey?: string;
}

export async function resolveStorageCredentials(
    databasePath: string,
    encryptionKey?: string
): Promise<IResolvedStorageCredentials>
```

Resolution logic:

**S3:**

S3 credentials are only looked up when `databasePath.startsWith('s3:')`. For local filesystem paths, skip this entire block and return `s3Config: undefined` immediately — no vault or env var access.

1. Look up databases.json entry by path → `vault.get(entry.s3Key)`
2. Else if `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` are set → use them (also respects `AWS_REGION`, `AWS_ENDPOINT`)

**Encryption key:**

Guard: if `encryptionKey` is not provided, `entry?.encryptionKey` is empty, and `PSI_ENCRYPTION_KEY` is not set → return `encryptionKeyPems: []` immediately, no vault access.

1. If `encryptionKey` is provided (from `-k`):
   - `await fs.access(value)` succeeds → read PEM from file
   - Else `await vault.has(value)` → load from vault
   - Else → error: neither a file nor a known secret
2. Else if `entry?.encryptionKey` is set → `vault.get(entry.encryptionKey)`
3. Else if `PSI_ENCRYPTION_KEY` env var is set:
   - `await fs.access(value)` succeeds → read PEM from file
   - Else `await vault.has(value)` → load from vault
   - Else → error: neither a file nor a known secret

**Geocoding:**

Guard: if `entry?.geocodingKey` is empty and `GOOGLE_API_KEY` is not set → return `googleApiKey: undefined` immediately, no vault access.

1. If `entry?.geocodingKey` is set → `vault.get(entry.geocodingKey)`
2. Else if `GOOGLE_API_KEY` env var is set → use it

**Verbose logging:**

After each resolution decision, emit a `log.verbose(...)` line explaining the outcome. No secret values are logged — only the source and reason. Examples:

```
S3 credentials: loaded from vault (key "my-s3-creds")
S3 credentials: loaded from environment variables (AWS_ACCESS_KEY_ID)
S3 credentials: not configured (no vault entry, no env vars)
Encryption key: loaded from file "/path/to/key.pem" (via -k flag)
Encryption key: loaded from vault (key "my-enc-key", via -k flag)
Encryption key: loaded from vault (key "my-enc-key", via databases.json entry)
Encryption key: loaded from file "/path/to/key.pem" (via PSI_ENCRYPTION_KEY)
Encryption key: loaded from vault (key "my-enc-key", via PSI_ENCRYPTION_KEY)
Encryption key: not configured
Geocoding key: loaded from vault (key "my-geo-key")
Geocoding key: loaded from environment variable (GOOGLE_API_KEY)
Geocoding key: not configured
```

### 3. Move and rename `IStorageDescriptor` → `IDatabaseDescriptor`

**Remove from:** `packages/storage/src/lib/storage-factory.ts`

**Create in:** `packages/api/src/lib/database-descriptor.ts`

Move the interface to `api` (which already depends on `storage`) and rename it. This is a fundamental semantic change, not just a rename: `encryptionKeyPems: IEncryptionKeyPem[]` is removed entirely (workers no longer receive pre-resolved PEM data), and `encryptionKey?: string` is added as an unresolved identifier (a file path or vault secret name) that workers pass to `resolveStorageCredentials` to obtain the actual PEM themselves. The descriptor carries only what workers cannot derive themselves:

```typescript
export interface IDatabaseDescriptor {
    databasePath: string;
    encryptionKey?: string; // file path or vault name from -k, if provided
}
```

Update all imports of `IStorageDescriptor` from `storage` to import `IDatabaseDescriptor` from `api` (or from within the `api` package directly).

### 4. Update all workers to self-resolve

All workers that currently receive `s3Config` or `encryptionKeyPems` switch to calling `resolveStorageCredentials()` instead:

- `verify.worker.ts` — remove `s3Config`, `storageDescriptor.encryptionKeyPems`; call `resolveStorageCredentials(storageDescriptor.databasePath, { encryptionKey: storageDescriptor.encryptionKey })`
- `check.worker.ts` — same
- `import-assets.worker.ts` — same
- `hash-file.worker.ts` — same
- `upload-asset.worker.ts` — same
- `sync-database.worker.ts` — call for local `databasePath`, then again for `config.origin`
- `prefetch-database.worker.ts` — call for local `databasePath`, then again for `config.origin`
- `load-assets.worker.ts` — call for `databasePath`
- `create-database.worker.ts` — call for `databasePath`
- `createLazyDatabaseStorage()` in `media-file-database.ts` — call for `databasePath` and origin

### 5. Update CLI commands to pass `encryptionKey` instead of resolved PEMs

**Files:** `apps/cli/src/lib/init-cmd.ts`, all commands that build `IDatabaseDescriptor`

Remove `validateEncryptionKey`. `loadDatabase()` calls `resolveStorageCredentials` for its own use to open the database in the main CLI thread, and this already runs before any workers are spawned — providing the same fail-fast behavior. If the `-k` value is neither a valid file nor a known vault secret, `resolveStorageCredentials` throws with a clear error at that point.

The unresolved `encryptionKey` value (the file path or vault name, not the resolved PEM) is passed into the database descriptor for workers to resolve themselves.

### 6. Rename credential fields in `IDatabaseEntry`

**File:** `packages/electron-defs/src/lib/electron-api.ts`

Rename the fields to reflect that they are vault encryptionKey names, not IDs:
- `s3CredentialId` → `s3Key`
- `encryptionKeyId` → `encryptionKey`
- `geocodingKeyId` → `geocodingKey`

Update all references across: `packages/lan-share/src/lib/lan-share-import.ts`, `packages/lan-share/src/lib/lan-share-resolve.ts`, `apps/desktop/src/main.ts`, `apps/cli/src/lib/init-cmd.ts`, `apps/cli/src/cmd/dbs.ts`, and all test files and smoke tests that reference these field names.

### 7. Remove `shared:` prefix

**File:** `apps/cli/src/lib/init-cmd.ts:393,405,415`

Remove `"shared:" +` from vault lookups in `init-cmd.ts` `resolveSecretsFromEntry()`.

### 8. Update smoke test seed data

**Files:** `apps/cli/smoke-tests.sh`, `apps/cli/smoke-tests-encrypted.sh`

Rename seeded vault secrets from `"shared:*"` to the bare ID (e.g., `"shared:s3test01"` → `"s3test01"`).

### 9. Add unit tests

**New file:** `packages/api/src/test/lib/resolve-storage-credentials.test.ts`

**S3:**
- Returns empty credentials for an unregistered path with no vault entry and no S3 env vars
- Uses `vault.get(entry.s3Key)` when entry is registered and has `s3Key` (takes priority over env vars)
- Falls back to `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` env vars when no vault entry exists

**Encryption key:**
- `-k` value points to an existing file → reads PEM from that file (highest priority)
- `-k` value is a vault secret name (`vault.has()` returns true) → loads from vault
- `-k` value is neither a file nor a vault secret → throws an error
- No `-k`, entry has `encryptionKey` in databases.json → `vault.get(entry.encryptionKey)` (second priority)
- No `-k`, no vault entry, `PSI_ENCRYPTION_KEY` env var set to a file path → reads PEM from file
- No `-k`, no vault entry, `PSI_ENCRYPTION_KEY` set to a vault secret name → loads from vault
- No `-k`, no vault entry, `PSI_ENCRYPTION_KEY` is neither a file nor a vault secret → throws an error

**Geocoding:**
- Entry has `geocodingKey` → `vault.get(entry.geocodingKey)` (highest priority)
- No vault entry, `GOOGLE_API_KEY` env var set → uses it

### 10. Add smoke test cases

**File:** `apps/cli/smoke-tests-encrypted.sh`

- Store an encryption key in the vault (not as a file), then run a CLI command with `-k <secret-name>`. Verifies `-k` accepts a vault secret name, not just a file path.
- Set `PSI_ENCRYPTION_KEY` to a vault secret name and run a CLI command without `-k`. Verifies the env var path works with a secret name.

**File:** `apps/cli/smoke-tests.sh`

- After adding an S3 database, trigger a sync (or verify the sync worker is exercised) to confirm `sync-database.worker.ts` correctly resolves S3 credentials. If no explicit sync step exists, add one.

---

## Critical Files

| File | Change |
|------|--------|
| `packages/api/package.json` | Add `vault` dependency |
| `packages/api/src/lib/resolve-storage-credentials.ts` | Create — single credential resolution utility |
| `packages/api/src/lib/database-descriptor.ts` | Create — `IDatabaseDescriptor` (moved + renamed from `storage`) |
| `packages/storage/src/lib/storage-factory.ts` | Remove `IStorageDescriptor` |
| `packages/api/src/lib/media-file-database.ts:584` | Fix `createLazyDatabaseStorage` |
| `packages/api/src/lib/verify.worker.ts` | Switch to self-resolve |
| `packages/api/src/lib/check.worker.ts` | Switch to self-resolve |
| `packages/api/src/lib/import-assets.worker.ts` | Switch to self-resolve |
| `packages/api/src/lib/hash-file.worker.ts` | Switch to self-resolve |
| `packages/api/src/lib/upload-asset.worker.ts` | Switch to self-resolve |
| `packages/api/src/lib/sync-database.worker.ts` | Switch to self-resolve |
| `packages/api/src/lib/prefetch-database.worker.ts` | Switch to self-resolve |
| `packages/api/src/lib/load-assets.worker.ts` | Switch to self-resolve |
| `packages/api/src/lib/create-database.worker.ts` | Switch to self-resolve |
| `packages/electron-defs/src/lib/electron-api.ts` | Rename `s3CredentialId/encryptionKeyId/geocodingKeyId` fields |
| `packages/lan-share/src/lib/lan-share-import.ts` | Field rename |
| `packages/lan-share/src/lib/lan-share-resolve.ts` | Field rename |
| `apps/desktop/src/main.ts` | Field rename + remove `shared:` prefix |
| `apps/cli/src/lib/init-cmd.ts` | Field rename + remove `shared:` prefix; pass `encryptionKey` not PEMs; import `IDatabaseDescriptor` from `api` |
| `apps/cli/src/cmd/dbs.ts` | Field rename |
| `apps/cli/smoke-tests.sh` | Field rename + update seeded vault secret names |
| `apps/cli/smoke-tests-encrypted.sh` | Update seeded vault secret names |
| `apps/cli/smoke-tests-lan-share.sh` | Update hardcoded JSON in `seed_databases_config` call: `s3CredentialId` → `s3Key`, `encryptionKeyId` → `encryptionKey` |

---


## Documentation Updates

Update any docs that reference the old field names, the `shared:` prefix, or the old credential passing behaviour:

**Wiki (`../photosphere.wiki/`):**
- `Command-Reference.md` — update `--key` / `-k` description to mention file path or vault secret name; add `PSI_ENCRYPTION_KEY` env var
- `Configuration-CLI.md` — update credential configuration section
- `Configuration-Cloud-Storage.md` — update S3 env var list; remove any mention of `shared:` prefix
- `Configuration-Digital-Ocean-Spaces.md` — same as above
- `Encryption.md` — update key resolution order (file → env var → vault); update `-k` description
- `Managing-Databases.md` — update field names (`s3Key`, `encryptionKey`, `geocodingKey`)
- `Managing-Secrets.md` — remove any mention of `shared:` prefix; update field names

**Repo docs (`docs/`):**
- Any plan docs that reference old field names or the `shared:` prefix (for historical accuracy, leave as-is — they describe past decisions)

---

## Verification

```bash
# Full monorepo compile + test
bun run compile
bun run test

# Smoke tests (require a configured S3 bucket and encryption key)
cd apps/cli && ./smoke-tests.sh
cd apps/cli && ./smoke-tests-encrypted.sh

# LAN share smoke tests
cd apps/cli && ./smoke-tests-lan-share.sh

# Sync smoke tests
cd apps/cli && ./sync-smoke-test.sh
```
