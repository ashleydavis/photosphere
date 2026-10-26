# CLI Manual Test: Set Origin

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `set-origin` records a database's origin, and that `sync` then uses it when no `--dest` is given.

## Prep

Move into the CLI source directory, clean up any previous test run, create a database with a file, replicate it, and add a second file to the replica:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
bun run start -- init --db /tmp/psi-test/main --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/main --yes
bun run start -- replicate --db /tmp/psi-test/main --dest /tmp/psi-test/backup --yes
bun run start -- add ../../test/test.png --db /tmp/psi-test/backup --yes
bun run start -- origin --db /tmp/psi-test/main
```

Expected:
- The database is created, the files are added and the replication completes.
- `origin` on `main` shows that it has no origin yet.

## Test

### 1. Set the origin of main to the backup

```bash
bun run start -- set-origin --db /tmp/psi-test/main /tmp/psi-test/backup --yes
```

Expected:
- The command exits successfully.

---

### 2. Sync without naming a destination

```bash
bun run start -- sync --db /tmp/psi-test/main --yes
```

Expected:
- The sync runs against `/tmp/psi-test/backup` and reports `Sync completed successfully`.

## Check

### 3. Confirm the origin and the synced file

```bash
bun run start -- origin --db /tmp/psi-test/main
cat /tmp/psi-test/main/.db/config.json
bun run start -- list --db /tmp/psi-test/main --yes
```

Expected:
- `origin` prints `/tmp/psi-test/backup`, and `.db/config.json` holds it as `origin`.
- `main` lists `test.jpg` and `test.png`.
