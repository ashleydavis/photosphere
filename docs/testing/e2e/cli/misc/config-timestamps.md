# CLI Manual Test: `.db/config.json` Timestamps

Test that `lastModifiedAt` and `lastSyncedAt` in `.db/config.json` update
across `add`, `sync`, and `repair`.

## Prerequisites

Navigate to the CLI source directory:

```bash
cd apps/cli/
```

## Steps

### 1. Clean up any previous test run

```bash
rm -rf /tmp/psi-test
```

---

### 2. Initialise a database

```bash
bun run start -- init --db /tmp/psi-test/db-add --yes
```

---

### 3. Confirm a fresh database has no `lastModifiedAt`

```bash
cat /tmp/psi-test/db-add/.db/config.json
```

Expected:
- The JSON object exists.
- It does not contain a `lastModifiedAt` field (or the field is absent / empty).

---

### 4. Add a file and confirm `lastModifiedAt` is set

```bash
bun run start -- add ../../test/test.png --db /tmp/psi-test/db-add --yes
cat /tmp/psi-test/db-add/.db/config.json
```

Expected:
- The config now contains a `lastModifiedAt` ISO-8601 timestamp.

---

### 5. Set up a sync pair and confirm both sides share the same `lastSyncedAt`

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

### 6. Repair after damage and confirm `lastModifiedAt` advances

```bash
bun run start -- init --db /tmp/psi-test/repair-source --yes
bun run start -- add ../../test/test.png --db /tmp/psi-test/repair-source --yes
bun run start -- replicate --db /tmp/psi-test/repair-source --dest /tmp/psi-test/repair-target --yes --force

# Note the current lastModifiedAt of the target.
cat /tmp/psi-test/repair-target/.db/config.json
```

Damage the target by deleting one of its asset files:

```bash
rm "$(find /tmp/psi-test/repair-target/asset -type f | head -1)"
sleep 1
bun run start -- repair --db /tmp/psi-test/repair-target --source /tmp/psi-test/repair-source --yes
cat /tmp/psi-test/repair-target/.db/config.json
```

Expected:
- The `lastModifiedAt` in `/tmp/psi-test/repair-target/.db/config.json` is now later than the pre-repair value.
