# CLI Manual Test: Sync After Editing a Field (Copy Side)

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that a field edit made via `bdb-cli` on the **copy** database is reflected
in the original after `sync`.

`bdb-cli` is the BSON database CLI the smoke tests use to change records directly. From `apps/cli/` it runs as `bun run ../bdb-cli/src/index.ts`.

## Prep

Move into the CLI source directory, clean up any previous test run, create the original database from the v6 fixture, replicate it to a copy, then edit a field on a known record in the **copy**:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test
cp -r ../../test/dbs/v6 /tmp/psi-test/original
bun run start -- replicate --db /tmp/psi-test/original --dest /tmp/psi-test/copy --yes --force
bun run ../bdb-cli/src/index.ts edit /tmp/psi-test/copy/.db/bson metadata 89171cd9-a652-4047-b869-1154bf2c95a1 description string "Edited on copy"
```

Expected:
- Replication completes successfully.
- The edit prints `Successfully updated field`.

## Test

### 1. Confirm root hashes now differ

```bash
bun run start -- root-hash --db /tmp/psi-test/original
bun run start -- root-hash --db /tmp/psi-test/copy
```

Expected:
- The two values are different.

---

### 2. Sync

```bash
bun run start -- sync --db /tmp/psi-test/original --dest /tmp/psi-test/copy --yes
```

Expected:
- Output includes `Sync completed successfully`.

## Check

### 3. Confirm the field is now also present on the original

```bash
bun run ../bdb-cli/src/index.ts record /tmp/psi-test/original/.db/bson metadata 89171cd9-a652-4047-b869-1154bf2c95a1 --all
bun run start -- root-hash --db /tmp/psi-test/original
bun run start -- root-hash --db /tmp/psi-test/copy
```

Expected:
- The record output contains `Edited on copy`.
- The root hashes for original and copy now match again.
