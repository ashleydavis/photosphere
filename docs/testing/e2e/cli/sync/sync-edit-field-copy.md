# CLI Manual Test: Sync After Editing a Field (Copy Side)

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that a field edit made via `bdb-cli` on the **copy** database is reflected
in the original after `sync`.

`bdb-cli` is the BSON database CLI the smoke tests use to change records directly. From the repo root it runs as `bun run apps/bdb-cli/src/index.ts`.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run, create the original database from the v6 fixture, replicate it to a copy, then edit a field on a known record in the **copy**:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-sync-sync-edit-field-copy
mkdir -p /tmp/psi-cli-sync-sync-edit-field-copy
cp -r test/dbs/v6 /tmp/psi-cli-sync-sync-edit-field-copy/original
psi replicate --db /tmp/psi-cli-sync-sync-edit-field-copy/original --dest /tmp/psi-cli-sync-sync-edit-field-copy/copy --yes --force
bun run apps/bdb-cli/src/index.ts edit /tmp/psi-cli-sync-sync-edit-field-copy/copy/.db/bson metadata 89171cd9-a652-4047-b869-1154bf2c95a1 description string "Edited on copy"
```

Expected:
- Replication completes successfully.
- The edit prints `Successfully updated field`.

## Test

### 1. Confirm root hashes now differ

```bash
psi root-hash --db /tmp/psi-cli-sync-sync-edit-field-copy/original
psi root-hash --db /tmp/psi-cli-sync-sync-edit-field-copy/copy
```

Expected:
- The two values are different.

---

### 2. Sync

```bash
psi sync --db /tmp/psi-cli-sync-sync-edit-field-copy/original --dest /tmp/psi-cli-sync-sync-edit-field-copy/copy --yes
```

Expected:
- Output includes `Sync completed successfully`.

## Check

### 3. Confirm the field is now also present on the original

```bash
bun run apps/bdb-cli/src/index.ts record /tmp/psi-cli-sync-sync-edit-field-copy/original/.db/bson metadata 89171cd9-a652-4047-b869-1154bf2c95a1 --all
psi root-hash --db /tmp/psi-cli-sync-sync-edit-field-copy/original
psi root-hash --db /tmp/psi-cli-sync-sync-edit-field-copy/copy
```

Expected:
- The record output contains `Edited on copy`.
- The root hashes for original and copy now match again.
