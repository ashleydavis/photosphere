# CLI Manual Test: Consolidate Into a New Remote

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `consolidate` creates the remote when nothing is there, records it as the origin, and leaves the two able to sync.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run, point the CLI at an empty config directory and create a local database with a file:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-origin-consolidate-new-remote
mkdir -p /tmp/psi-cli-origin-consolidate-new-remote/config
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-origin-consolidate-new-remote/config
psi init --db /tmp/psi-cli-origin-consolidate-new-remote/local --yes
psi add test/test.jpg --db /tmp/psi-cli-origin-consolidate-new-remote/local --yes
```

Expected:
- The database is created and the file is added.

## Test

### 1. Consolidate into a remote that does not exist

```bash
psi consolidate --db /tmp/psi-cli-origin-consolidate-new-remote/local /tmp/psi-cli-origin-consolidate-new-remote/remote --yes
```

Expected:
- The command exits successfully and reports that the remote was created.

---

### 2. Add a file locally and sync without naming a destination

```bash
psi add test/test.png --db /tmp/psi-cli-origin-consolidate-new-remote/local --yes
psi sync --db /tmp/psi-cli-origin-consolidate-new-remote/local --yes
```

Expected:
- The sync runs against the remote and reports `Sync completed successfully`.

## Check

### 3. Confirm the origin and that the remote matches

```bash
psi origin --db /tmp/psi-cli-origin-consolidate-new-remote/local
psi list --db /tmp/psi-cli-origin-consolidate-new-remote/remote --yes
psi compare --db /tmp/psi-cli-origin-consolidate-new-remote/local --dest /tmp/psi-cli-origin-consolidate-new-remote/remote --yes
psi verify --db /tmp/psi-cli-origin-consolidate-new-remote/remote --yes
```

Expected:
- `origin` prints `/tmp/psi-cli-origin-consolidate-new-remote/remote`.
- The remote lists `test.jpg` and `test.png`.
- `compare` reports `No differences detected`, and the remote verifies.
