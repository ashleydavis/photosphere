# CLI Manual Test: Consolidate With an Unrelated Remote

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `consolidate` joins a local database to a remote that holds a different database, so that the two can sync, without losing either side's files.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run, point the CLI at an empty config directory, and create two unrelated databases, each with its own file:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-origin-consolidate-unrelated-remote
mkdir -p /tmp/psi-cli-origin-consolidate-unrelated-remote/config
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-origin-consolidate-unrelated-remote/config
psi init --db /tmp/psi-cli-origin-consolidate-unrelated-remote/local --yes
psi add test/test.jpg --db /tmp/psi-cli-origin-consolidate-unrelated-remote/local --yes
psi init --db /tmp/psi-cli-origin-consolidate-unrelated-remote/remote --yes
psi add test/test.png --db /tmp/psi-cli-origin-consolidate-unrelated-remote/remote --yes
```

Expected:
- Both databases are created and each has one file.

## Test

### 1. Confirm sync refuses the two before they are joined

```bash
psi sync --db /tmp/psi-cli-origin-consolidate-unrelated-remote/local --dest /tmp/psi-cli-origin-consolidate-unrelated-remote/remote --yes
```

Expected:
- The command exits with a non-zero status and says the databases are not related.

---

### 2. Consolidate the local database with the remote

```bash
psi consolidate --db /tmp/psi-cli-origin-consolidate-unrelated-remote/local /tmp/psi-cli-origin-consolidate-unrelated-remote/remote --yes
```

Expected:
- The command exits successfully.

---

### 3. Sync without naming a destination

```bash
psi sync --db /tmp/psi-cli-origin-consolidate-unrelated-remote/local --yes
```

Expected:
- The sync runs against the remote and reports `Sync completed successfully`.

## Check

### 4. Confirm neither side lost a file and the two match

```bash
psi origin --db /tmp/psi-cli-origin-consolidate-unrelated-remote/local
psi list --db /tmp/psi-cli-origin-consolidate-unrelated-remote/local --yes
psi list --db /tmp/psi-cli-origin-consolidate-unrelated-remote/remote --yes
psi compare --db /tmp/psi-cli-origin-consolidate-unrelated-remote/local --dest /tmp/psi-cli-origin-consolidate-unrelated-remote/remote --yes
psi verify --db /tmp/psi-cli-origin-consolidate-unrelated-remote/local --yes
```

Expected:
- `origin` prints `/tmp/psi-cli-origin-consolidate-unrelated-remote/remote`.
- Both sides list `test.jpg` and `test.png`.
- `compare` reports `No differences detected`, and the local database verifies.
