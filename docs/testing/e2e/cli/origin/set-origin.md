# CLI Manual Test: Set Origin

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `set-origin` records a database's origin, and that `sync` then uses it when no `--dest` is given.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run, point the CLI at an empty config directory, create a database with a file, replicate it, and add a second file to the replica:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-origin-set-origin
mkdir -p /tmp/psi-cli-origin-set-origin/config
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-origin-set-origin/config
psi init --db /tmp/psi-cli-origin-set-origin/main --yes
psi add test/test.jpg --db /tmp/psi-cli-origin-set-origin/main --yes
psi replicate --db /tmp/psi-cli-origin-set-origin/main --dest /tmp/psi-cli-origin-set-origin/backup --yes
psi add test/test.png --db /tmp/psi-cli-origin-set-origin/backup --yes
psi origin --db /tmp/psi-cli-origin-set-origin/main
```

Expected:
- The database is created, the files are added and the replication completes.
- `origin` on `main` shows that it has no origin yet.

## Test

### 1. Set the origin of main to the backup

```bash
psi set-origin --db /tmp/psi-cli-origin-set-origin/main /tmp/psi-cli-origin-set-origin/backup --yes
```

Expected:
- The command exits successfully.

---

### 2. Sync without naming a destination

```bash
psi sync --db /tmp/psi-cli-origin-set-origin/main --yes
```

Expected:
- The sync runs against `/tmp/psi-cli-origin-set-origin/backup` and reports `Sync completed successfully`.

## Check

### 3. Confirm the origin and the synced file

```bash
psi origin --db /tmp/psi-cli-origin-set-origin/main
cat /tmp/psi-cli-origin-set-origin/main/.db/config.json
psi list --db /tmp/psi-cli-origin-set-origin/main --yes
```

Expected:
- `origin` prints `/tmp/psi-cli-origin-set-origin/backup`, and `.db/config.json` holds it as `origin`.
- `main` lists `test.jpg` and `test.png`.
