# Plan: `psi dbs` Command and Database List Integration

## Context

The Photosphere desktop app manages a list of configured databases in `~/.config/photosphere/databases.json`. Each entry (`IDatabaseEntry`) has a name, path, and optional references to shared vault secrets (S3 credentials, encryption keys, geocoding API keys). A parallel change is removing the `id` field from `IDatabaseEntry` — databases are identified by **name** or **path**, not UUIDs.

The CLI tool currently has no way to manage this list or use it. This change adds:
1. A `psi dbs` command for CRUD management of the database list
2. Automatic secret resolution: when `--db <path>` matches an entry in databases.json, its linked S3 credentials, encryption key, and geocoding key are resolved from the vault automatically — no need for separate `--key` or S3 config. When `--db <name>` is used, the entry is looked up by name. If a path isn't in databases.json, that's fine — existing manual config flows still work.

---

## Part 1: `psi dbs` Command Group

### New file: `apps/cli/src/cmd/dbs.ts`

Follow the `vault.ts` subcommand pattern — export `dbsCommand(): Command`.

**Sub-commands:**

| Command | Description |
|---------|-------------|
| `psi dbs list` | Table of all configured databases (name, path, encrypted?, s3?) |
| `psi dbs add` | Interactive prompts: name, description, path, optional secret linking |
| `psi dbs view <name>` | Show all fields of a database entry (look up by name) |
| `psi dbs edit <name>` | Edit fields with current values pre-populated |
| `psi dbs remove <name>` | Remove with confirmation |

**Key details:**
- Reuse `getDatabases()`, `addDatabaseEntry()`, `updateDatabaseEntry()`, `removeDatabaseEntry()` from `packages/node-utils/src/lib/databases-config.ts`
- No ID generation needed — entries are identified by name/path (aligns with UUID removal plan)
- For `view`/`edit`/`remove`: look up by name using case-insensitive match; error if no match or ambiguous
- Use `intro()`/`outro()`/`text()`/`select()`/`confirm()` from clack prompts, matching vault.ts style

**Secret picker during `add`/`edit`:**

For each secret type (S3 credentials, encryption key, geocoding API key), present a `select()` prompt with:
1. **"None"** — no secret linked (default)
2. **Existing secrets** — list vault entries filtered by `shared:` prefix and matching type (e.g. `s3-credentials`). Display the label from the parsed JSON value. Vault entries are `{ name: "shared:{id}", type: "s3-credentials", value: "{\"label\":\"...\", ...}" }` — extract the `label` field for display, use the `{id}` portion as the value to store in the database entry's `s3CredentialId`/`encryptionKeyId`/`geocodingKeyId`.
3. **"+ Create new"** — inline creation flow, type-specific:
   - **S3 credentials**: prompt for label, endpoint, region, access key ID, secret access key. Generate an 8-char ID, store in vault as `shared:{id}` with type `s3-credentials` and JSON value `{ label, region, accessKeyId, secretAccessKey, endpoint }`.
   - **Encryption key**: prompt for label, then either prompt for private/public PEM paths (import) or offer to generate a new key pair (using `generateKeyPair()`/`exportPublicKeyToPem()` from `storage` package). Store as `shared:{id}` with type `encryption-key` and JSON value `{ label, privateKeyPem, publicKeyPem }`.
   - **API key**: prompt for label and API key value. Store as `shared:{id}` with type `api-key` and JSON value `{ label, apiKey }`.

Helper function `generateSharedSecretId(): string` — same 8-char `[a-z0-9]` pattern. This generates the ID for the vault key name `shared:{id}`, not for the database entry itself.

Helper function `pickOrCreateSecret(type: string, currentId?: string): Promise<string | undefined>` — encapsulates the select/create flow above. Returns the secret ID to store on the database entry, or `undefined` for "None". When editing, highlight the current selection.

### Modify: `apps/cli/index.ts`

- Import `dbsCommand` from `./src/cmd/dbs`
- Add `program.addCommand(dbsCommand());` next to the vault line (~line 541)

### Modify: `apps/cli/src/examples.ts`

Add `dbs` examples:
- `psi dbs list` — "List all configured databases"
- `psi dbs add` — "Add a new database to the list"
- `psi dbs view my-photos` — "View details of a database entry"
- `psi dbs edit my-photos` — "Edit a database entry"
- `psi dbs remove my-photos` — "Remove a database entry"

---

## Part 2: Automatic Secret Resolution from Database List

### Modify: `apps/cli/src/lib/init-cmd.ts`

**New function: `resolveDatabaseEntry(dbValue: string): Promise<IDatabaseEntry | undefined>`**
- Load all databases via `getDatabases()`
- Try exact path match first, then case-insensitive name match
- Return `undefined` if no match (not an error — `dbValue` is treated as a raw path)
- Error only if multiple name matches (list them so user can disambiguate)

**New function: `resolveSecretsFromEntry(entry: IDatabaseEntry): Promise<IResolvedDatabaseSecrets>`**

New interface:
```typescript
interface IResolvedDatabaseSecrets {
    s3Config?: IS3Credentials;
    keyPems: IEncryptionKeyPem[];
    googleApiKey?: string;
}
```

Resolution logic (matches desktop `main.ts` pattern):
- `entry.s3CredentialId` → `vault.get(\`shared:${id}\`)` → parse JSON → `IS3Credentials`
- `entry.encryptionKeyId` → `vault.get(\`shared:${id}\`)` → parse JSON → `IEncryptionKeyPem`
- `entry.geocodingKeyId` → `vault.get(\`shared:${id}\`)` → parse JSON → extract `apiKey`

**Modify `loadDatabase()`:**

After `dbDir` is resolved (either from `--db` or interactive picker), but before creating storage:

1. Call `resolveDatabaseEntry(dbDir)` — tries path match, then name match
2. If a match is found:
   - If matched by name, set `dbDir = entry.path` (the name resolved to a path)
   - Call `resolveSecretsFromEntry(entry)`:
     - Use resolved `s3Config` instead of `getS3Config()` (skip `configureIfNeeded(['s3'])`)
     - Use resolved `keyPems` instead of `resolveKeyPems(options.key)` (skip `--key` requirement)
     - Store resolved `googleApiKey` on `IInitResult` for commands that need geocoding
3. If no match: proceed with existing manual config flows (`--key`, `getS3Config()`, interactive S3 setup) — the `--db` value is used as a raw path as before

No new CLI options needed — the existing `--db` option gains the ability to match by name.

**Add `googleApiKey` to `IInitResult`:**
- New optional field so commands like `add` can use the geocoding key from the database entry

---

## Part 3: Documentation

### Modify: `apps/cli/README.md`

- Add `psi dbs` section documenting all sub-commands (`list`, `add`, `view`, `edit`, `remove`)
- Document the `--db` name resolution behaviour: `--db` now accepts a database name in addition to a path; if it matches an entry in databases.json, linked secrets are auto-resolved
- Add examples showing `psi dbs list`, `psi dbs add`, and `psi info --db my-photos`

### Modify: `apps/cli/src/examples.ts`

Add `dbs` examples (as listed in Part 1) and update `--db` examples in existing commands to show name-based usage (e.g. `psi summary --db my-photos`).

### Modify: wiki `Command-Reference.md` (`/home/ash/projects/photosphere/photosphere.wiki/Command-Reference.md`)

- Add `dbs` command section with all sub-commands (`list`, `add`, `view`, `edit`, `remove`), options, and examples
- Add `vault` command section with all sub-commands (`add`, `list`, `view`, `edit`, `delete`, `import`), options, and examples — currently undocumented in the wiki
- Update the Global Options section: note that `--db` now accepts a database name in addition to a path, with automatic secret resolution from databases.json

### Modify: wiki `Getting-Started-CLI.md` (`/home/ash/projects/photosphere/photosphere.wiki/Getting-Started-CLI.md`)

- Add a section on managing databases with `psi dbs` (register, list, remove)
- Show the workflow: register a database with `psi dbs add`, then use `psi summary --db my-photos` by name
- Update the Typical Workflow at the bottom to mention `psi dbs` as an optional step after init

---

## Part 4: Smoke Tests

### Prerequisite: test isolation for databases.json

The config directory is hardcoded to `~/.config/photosphere/` in `packages/node-utils/src/lib/databases-config.ts`. Add a `PHOTOSPHERE_CONFIG_DIR` env var override (matching the `PHOTOSPHERE_VAULT_DIR` pattern in `packages/vault/src/lib/get-vault.ts`), so smoke tests can isolate the databases.json file without polluting the user's real config.

### New file: `apps/cli/smoke-tests-dbs.sh`

A dedicated smoke test script for the `vault` and `dbs` commands. Uses the same test framework patterns as `smoke-tests-encrypted.sh` (test table, `invoke_command`, `check_output_contains`, etc.). Sets `PHOTOSPHERE_VAULT_DIR` and `PHOTOSPHERE_CONFIG_DIR` to isolated temp dirs.

**Vault smoke tests** (non-interactive, using `--yes` or direct vault file manipulation where needed):

| Test | Description |
|------|-------------|
| `vault-add-s3` | Add an S3 credentials secret to the vault, verify it appears in `vault list` |
| `vault-add-encryption-key` | Add an encryption key secret, verify it appears in `vault list` |
| `vault-add-api-key` | Add an API key secret, verify it appears in `vault list` |
| `vault-view` | View a secret by name, verify output contains expected fields |
| `vault-delete` | Delete a secret, verify it no longer appears in `vault list` |

Since the vault `add` command is interactive, these tests will seed secrets by writing vault files directly (the vault is just JSON files in a directory), then verify `vault list` and `vault view` work correctly.

**Dbs smoke tests** (non-interactive, seeding databases.json and vault directly):

| Test | Description |
|------|-------------|
| `dbs-list-empty` | `psi dbs list` with no databases configured — verify "No databases" message |
| `dbs-add` | Seed a database entry into databases.json, verify `psi dbs list` shows it |
| `dbs-view` | `psi dbs view <name>` — verify output shows name, path, and linked secret IDs |
| `dbs-remove` | `psi dbs remove <name> --yes` — verify entry is removed from list |
| `dbs-resolve-by-name` | Create a database with `psi init`, register it in databases.json with a linked encryption key, then run `psi summary --db <name>` — verify it resolves the database by name and uses the linked encryption key |
| `dbs-resolve-by-path` | Same setup but use `psi summary --db <path>` — verify it auto-resolves linked secrets from the matching databases.json entry |
| `dbs-no-match-fallback` | Run `psi summary --db <path>` with a path that is NOT in databases.json — verify it still works using existing manual config flows |

### Modify: `apps/cli/README.md`

Add a section documenting how to run the new smoke tests:
```bash
./smoke-tests-dbs.sh all
./smoke-tests-dbs.sh --debug all
./smoke-tests-dbs.sh vault-list
```

---

## Files to modify/create

| File | Action |
|------|--------|
| `apps/cli/src/cmd/dbs.ts` | **Create** — new `dbs` command group |
| `apps/cli/index.ts` | **Modify** — register `dbs` command |
| `apps/cli/src/lib/init-cmd.ts` | **Modify** — add `resolveDatabaseEntry`, `resolveSecretsFromEntry`, modify `loadDatabase` to resolve db entries by name or path |
| `apps/cli/src/examples.ts` | **Modify** — add `dbs` examples, update existing examples |
| `apps/cli/README.md` | **Modify** — document `dbs` command, `--db` name resolution, new smoke tests |
| `apps/cli/smoke-tests-dbs.sh` | **Create** — smoke tests for `vault` and `dbs` commands |
| `packages/node-utils/src/lib/databases-config.ts` | **Modify** — add `PHOTOSPHERE_CONFIG_DIR` env var override for test isolation |
| `photosphere.wiki/Command-Reference.md` | **Modify** — add `dbs` and `vault` command docs, update `--db` global option |
| `photosphere.wiki/Getting-Started-CLI.md` | **Modify** — add database management section with `psi dbs` workflow |

## Existing code to reuse

- `packages/node-utils/src/lib/databases-config.ts` — all CRUD functions
- `packages/electron-defs/src/lib/electron-api.ts` — `IDatabaseEntry` interface
- `packages/vault/src/lib/vault.ts` — `getVault("plaintext")` for secret resolution
- `apps/cli/src/cmd/vault.ts` — pattern reference for subcommand structure
- `apps/desktop/src/main.ts` lines 318-350 — pattern for resolving `shared:{id}` secrets
- `apps/cli/smoke-tests-encrypted.sh` — pattern reference for smoke test structure and vault isolation

## Verification

1. `bun run compile` from root — TypeScript compiles clean
2. `bun run test` in `apps/cli/` — existing tests pass
3. `./smoke-tests-dbs.sh all` — new smoke tests pass
4. `./smoke-tests.sh all` — existing smoke tests still pass (no regressions)
5. Manual testing:
   - `psi dbs list` — should show empty list initially
   - `psi dbs add` — add a database entry interactively
   - `psi dbs list` — should show the new entry
   - `psi dbs view my-photos` — should show full details
   - `psi dbs edit my-photos` — should allow editing
   - `psi dbs remove my-photos` — should remove with confirmation
   - `psi info --db my-photos` — should resolve "my-photos" by name from databases.json, auto-resolve secrets
   - `psi info --db /path/to/db` — if path is in databases.json, should auto-resolve secrets; if not, should work as before
