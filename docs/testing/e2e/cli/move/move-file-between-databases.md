# CLI Manual Test: Move File Between Databases

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

> **Warning:** The `psi move` command is not yet implemented.

Test that a file can be imported into one database and moved to another using the CLI.

## Prep

Move into the CLI source directory, clean up any previous test run, create a source database, import a file and create a second database:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
bun run start -- init --db /tmp/psi-test/source --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/source
bun run start -- init --db /tmp/psi-test/dest --yes
```

Expected:
- Output confirms new media file databases were created in `/tmp/psi-test/source` and `/tmp/psi-test/dest`.
- The file is reported as added, with no errors.

## Test

### 1. Move the file to the destination database

```bash
bun run start -- move ../../test/test.jpg --db /tmp/psi-test/source --dest /tmp/psi-test/dest
```

Expected:
- The file is reported as moved.
- No errors are shown.

## Check

### 2. Check that the file is no longer in the source database

```bash
bun run start -- list --db /tmp/psi-test/source
```

Expected:
- No files are listed.

---

### 3. Check that the file is now in the destination database

```bash
bun run start -- list --db /tmp/psi-test/dest
```

Expected:
- `test.jpg` is listed.
