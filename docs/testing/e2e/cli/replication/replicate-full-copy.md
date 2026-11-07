# CLI Manual Test: Replicate Full Copy

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that a database can be created, populated, verified, and fully replicated to a new directory using the CLI.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run, create a database, import a file, list it and verify the source:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-replication-replicate-full-copy
psi init --db /tmp/psi-cli-replication-replicate-full-copy/source --yes
psi add test/test.jpg --db /tmp/psi-cli-replication-replicate-full-copy/source
psi list --db /tmp/psi-cli-replication-replicate-full-copy/source
psi verify --db /tmp/psi-cli-replication-replicate-full-copy/source
```

Expected:
- Output confirms a new media file database was created in `/tmp/psi-cli-replication-replicate-full-copy/source`.
- The file is reported as added, with no errors.
- `test.jpg` is listed.
- Verification completes without errors and all files pass integrity checks.

## Test

### 1. Replicate a full copy to a new directory

```bash
psi replicate --db /tmp/psi-cli-replication-replicate-full-copy/source --dest /tmp/psi-cli-replication-replicate-full-copy/replica --full --yes
```

Expected:
- Replication results show files copied.
- `✅ Replication completed successfully` is shown.

## Check

### 2. List files in the replica database

```bash
psi list --db /tmp/psi-cli-replication-replicate-full-copy/replica
```

Expected:
- `test.jpg` is listed.

---

### 3. Check that the replica database is ok

```bash
psi verify --db /tmp/psi-cli-replication-replicate-full-copy/replica
```

Expected:
- Verification completes without errors.
- All files pass integrity checks.

---

### 4. Check the origin of the replica

```bash
psi origin --db /tmp/psi-cli-replication-replicate-full-copy/replica
```

Expected:
- The origin is shown as `/tmp/psi-cli-replication-replicate-full-copy/source`.
