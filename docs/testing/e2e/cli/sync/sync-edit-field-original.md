# CLI Manual Test: Sync After Editing a Field (Original Side)

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that a field edit made via `bdb-cli` on the original database is reflected
in the copy after `sync`.

`bdb-cli` is the BSON database CLI the smoke tests use to change records directly. From the repo root it runs as `bun run apps/bdb-cli/src/index.ts`.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run, create the original database from the v6 fixture, replicate it to a copy, then edit a field on a known record in the original (the v6 fixture ships record id `89171cd9-a652-4047-b869-1154bf2c95a1`):

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-sync-sync-edit-field-original
mkdir -p /tmp/psi-cli-sync-sync-edit-field-original
cp -r test/dbs/v6 /tmp/psi-cli-sync-sync-edit-field-original/original
psi replicate --db /tmp/psi-cli-sync-sync-edit-field-original/original --dest /tmp/psi-cli-sync-sync-edit-field-original/copy --yes --force
bun run apps/bdb-cli/src/index.ts edit /tmp/psi-cli-sync-sync-edit-field-original/original/.db/bson metadata 89171cd9-a652-4047-b869-1154bf2c95a1 description string "Edited on original"
```

Expected:
- Replication completes successfully.
- The edit prints `Successfully updated field`.

## Test

### 1. Read the field back to confirm

```bash
bun run apps/bdb-cli/src/index.ts record /tmp/psi-cli-sync-sync-edit-field-original/original/.db/bson metadata 89171cd9-a652-4047-b869-1154bf2c95a1 --all
```

Expected:
- Output contains `Edited on original`.

---

### 2. Confirm root hashes now differ

```bash
psi root-hash --db /tmp/psi-cli-sync-sync-edit-field-original/original
psi root-hash --db /tmp/psi-cli-sync-sync-edit-field-original/copy
```

Expected:
- The two values are different.

---

### 3. Sync

```bash
psi sync --db /tmp/psi-cli-sync-sync-edit-field-original/original --dest /tmp/psi-cli-sync-sync-edit-field-original/copy --yes
```

Expected:
- Output includes `Sync completed successfully`.

## Check

### 4. Confirm the field is now also present on the copy

```bash
bun run apps/bdb-cli/src/index.ts record /tmp/psi-cli-sync-sync-edit-field-original/copy/.db/bson metadata 89171cd9-a652-4047-b869-1154bf2c95a1 --all
psi root-hash --db /tmp/psi-cli-sync-sync-edit-field-original/original
psi root-hash --db /tmp/psi-cli-sync-sync-edit-field-original/copy
```

Expected:
- The record output contains `Edited on original`.
- The root hashes for original and copy now match again.
