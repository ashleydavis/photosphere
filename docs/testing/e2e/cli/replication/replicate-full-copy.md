# CLI Manual Test: Replicate Full Copy

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that a database can be created, populated, verified, and fully replicated to a new directory using the CLI source.

## Prep

Move into the CLI source directory, clean up any previous test run, create a database, import a file, list it and verify the source:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
bun run start -- init --db /tmp/psi-test/source --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/source
bun run start -- list --db /tmp/psi-test/source
bun run start -- verify --db /tmp/psi-test/source
```

Expected:
- Output confirms a new media file database was created in `/tmp/psi-test/source`.
- The file is reported as added, with no errors.
- `test.jpg` is listed.
- Verification completes without errors and all files pass integrity checks.

## Test

### 1. Replicate a full copy to a new directory

```bash
bun run start -- replicate --db /tmp/psi-test/source --dest /tmp/psi-test/replica --full --yes
```

Expected:
- Replication results show files copied.
- `✅ Replication completed successfully` is shown.

## Check

### 2. List files in the replica database

```bash
bun run start -- list --db /tmp/psi-test/replica
```

Expected:
- `test.jpg` is listed.

---

### 3. Check that the replica database is ok

```bash
bun run start -- verify --db /tmp/psi-test/replica
```

Expected:
- Verification completes without errors.
- All files pass integrity checks.

---

### 4. Check the origin of the replica

```bash
bun run start -- origin --db /tmp/psi-test/replica
```

Expected:
- The origin is shown as `/tmp/psi-test/source`.
