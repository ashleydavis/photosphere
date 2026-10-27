# CLI Manual Test: Move File Between Databases

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

> **Warning:** The `psi move` command is not yet implemented.

Test that a file can be imported into one database and moved to another using the CLI.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run, create a source database, import a file and create a second database:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-move-move-file-between-databases
psi init --db /tmp/psi-cli-move-move-file-between-databases/source --yes
psi add test/test.jpg --db /tmp/psi-cli-move-move-file-between-databases/source
psi init --db /tmp/psi-cli-move-move-file-between-databases/dest --yes
```

Expected:
- Output confirms new media file databases were created in `/tmp/psi-cli-move-move-file-between-databases/source` and `/tmp/psi-cli-move-move-file-between-databases/dest`.
- The file is reported as added, with no errors.

## Test

### 1. Move the file to the destination database

```bash
psi move test/test.jpg --db /tmp/psi-cli-move-move-file-between-databases/source --dest /tmp/psi-cli-move-move-file-between-databases/dest
```

Expected:
- The file is reported as moved.
- No errors are shown.

## Check

### 2. Check that the file is no longer in the source database

```bash
psi list --db /tmp/psi-cli-move-move-file-between-databases/source
```

Expected:
- No files are listed.

---

### 3. Check that the file is now in the destination database

```bash
psi list --db /tmp/psi-cli-move-move-file-between-databases/dest
```

Expected:
- `test.jpg` is listed.
