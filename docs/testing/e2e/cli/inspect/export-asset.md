# CLI Manual Test: Export an Asset by ID

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `export` writes an asset's original bytes to a chosen destination.

## Prep

Move into the CLI source directory, clean up any previous test run, create a database, add a file, read its asset ID and make the export directory:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
bun run start -- init --db /tmp/psi-test/source --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/source --yes
ls /tmp/psi-test/source/asset
mkdir -p /tmp/psi-test/exports
```

Expected:
- Database created and the file is reported as added.
- `ls` lists one file whose name is a UUID (e.g. `89171cd9-a652-4047-b869-1154bf2c95a1`). Record that UUID and substitute it for `<asset-id>` below.

## Test

### 1. Export the original asset to a file

```bash
bun run start -- export --db /tmp/psi-test/source <asset-id> /tmp/psi-test/exports/out.jpg --yes
```

Expected:
- Output contains `Successfully exported`.

---

### 2. Export a non-existent asset

```bash
bun run start -- export --db /tmp/psi-test/source 00000000-0000-0000-0000-000000000000 /tmp/psi-test/exports/missing.jpg --yes
```

Expected:
- The command exits with a non-zero status and reports that the asset cannot be found.

## Check

### 3. Confirm which export files exist

```bash
ls -l /tmp/psi-test/exports/
cmp /tmp/psi-test/exports/out.jpg ../../test/test.jpg
```

Expected:
- `out.jpg` exists and `cmp` prints nothing, so it is identical to the file that was added.
- `missing.jpg` was not created.
