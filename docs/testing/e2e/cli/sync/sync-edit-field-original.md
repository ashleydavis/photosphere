# CLI Manual Test: Sync After Editing a Field (Original Side)

Test that a field edit made via `bdb-cli` on the original database is reflected
in the copy after `sync`.

## Prerequisites

Navigate to the CLI source directory:

```bash
cd apps/cli/
```

The `bdb-cli` binary is the BSON database CLI used by the smoke tests to mutate
records directly. From the repo root it is available as
`bun --cwd packages/bson-database/bin start` or whichever wrapper the local
checkout exposes. The smoke-test runner uses a `get_bdb_command` helper for
this — pick whichever invocation matches your local checkout.

## Steps

### 1. Clean up any previous test run

```bash
rm -rf /tmp/psi-test
```

---

### 2. Create the original database from the v6 fixture and replicate to a copy

```bash
cp -r ../../test/dbs/v6 /tmp/psi-test/original
bun run start -- replicate --db /tmp/psi-test/original --dest /tmp/psi-test/copy --yes --force
```

Expected:
- Replication completes successfully.

---

### 3. Edit a field on a known record in the original

The v6 fixture ships a known record id `89171cd9-a652-4047-b869-1154bf2c95a1`.

```bash
<bdb-cli> edit /tmp/psi-test/original/.db/bson metadata 89171cd9-a652-4047-b869-1154bf2c95a1 description string "Edited on original"
```

Expected:
- Output includes `Successfully updated field`.

---

### 4. Read the field back to confirm

```bash
<bdb-cli> record /tmp/psi-test/original/.db/bson metadata 89171cd9-a652-4047-b869-1154bf2c95a1 --all
```

Expected:
- Output contains `Edited on original`.

---

### 5. Confirm root hashes now differ

```bash
bun run start -- root-hash --db /tmp/psi-test/original
bun run start -- root-hash --db /tmp/psi-test/copy
```

Expected:
- The two values are different.

---

### 6. Sync

```bash
bun run start -- sync --db /tmp/psi-test/original --dest /tmp/psi-test/copy --yes
```

Expected:
- Output includes `Sync completed successfully`.

---

### 7. Confirm the field is now also present on the copy

```bash
<bdb-cli> record /tmp/psi-test/copy/.db/bson metadata 89171cd9-a652-4047-b869-1154bf2c95a1 --all
```

Expected:
- Output contains `Edited on original`.
- The root hashes for original and copy now match again.
