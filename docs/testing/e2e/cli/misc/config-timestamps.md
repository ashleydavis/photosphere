# CLI Manual Test: `.db/config.json` Timestamps

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

> **Warning:** This test is out of date. `lastModifiedAt` and `lastSyncedAt` are no longer written to `.db/config.json`, which now holds only `origin`. They live in the binary `.db/state.dat` (see `packages/api/src/lib/database-state.ts`), and no CLI command prints them, so the expectations below cannot pass as written.

Test that `lastModifiedAt` and `lastSyncedAt` in `.db/config.json` update
across `add`, `sync`, and `repair`.

## Prep

Move into the CLI source directory, clean up any previous test run and initialise a database:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
bun run start -- init --db /tmp/psi-test/db-add --yes
```

Expected:
- The database is created.

## Test

### 1. Confirm a fresh database has no `lastModifiedAt`

```bash
cat /tmp/psi-test/db-add/.db/config.json
```

Expected:
- The JSON object exists.
- It does not contain a `lastModifiedAt` field (or the field is absent / empty).

---

### 2. Add a file and confirm `lastModifiedAt` is set

```bash
bun run start -- add ../../test/test.png --db /tmp/psi-test/db-add --yes
cat /tmp/psi-test/db-add/.db/config.json
```

Expected:
- The config now contains a `lastModifiedAt` ISO-8601 timestamp.

---

### 3. Set up a sync pair and confirm both sides share the same `lastSyncedAt`

```bash
bun run start -- init --db /tmp/psi-test/sync-source --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/sync-source --yes
bun run start -- replicate --db /tmp/psi-test/sync-source --dest /tmp/psi-test/sync-replica --yes --force
bun run start -- sync --db /tmp/psi-test/sync-source --dest /tmp/psi-test/sync-replica --yes
cat /tmp/psi-test/sync-source/.db/config.json
cat /tmp/psi-test/sync-replica/.db/config.json
```

Expected:
- Both files contain a `lastSyncedAt` field with the same ISO-8601 timestamp.

---

### 4. Repair after damage and confirm `lastModifiedAt` advances

```bash
bun run start -- init --db /tmp/psi-test/repair-source --yes
bun run start -- add ../../test/test.png --db /tmp/psi-test/repair-source --yes
bun run start -- replicate --db /tmp/psi-test/repair-source --dest /tmp/psi-test/repair-target --yes --force
# Note the current lastModifiedAt of the target.
cat /tmp/psi-test/repair-target/.db/config.json
```

Damage the target by deleting one of its asset files, then repair it:

```bash
rm "$(find /tmp/psi-test/repair-target/asset -type f | head -1)"
sleep 1
bun run start -- repair --db /tmp/psi-test/repair-target --source /tmp/psi-test/repair-source --yes
cat /tmp/psi-test/repair-target/.db/config.json
```

Expected:
- The `lastModifiedAt` in `/tmp/psi-test/repair-target/.db/config.json` is now later than the pre-repair value.

## Check

The `cat` output in each step is the check.
