# CLI Manual Test: Remove an Asset by ID

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `remove` deletes an asset from the database and from on-disk storage.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run, create a database, add a file and read its asset ID:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-remove-remove-asset-by-id
psi init --db /tmp/psi-cli-remove-remove-asset-by-id/source --yes
psi add test/test.jpg --db /tmp/psi-cli-remove-remove-asset-by-id/source --yes
ls /tmp/psi-cli-remove-remove-asset-by-id/source/asset
```

Expected:
- Database created and the file is reported as added.
- `ls` lists one UUID-named file. Record that UUID and use it as `<asset-id>` below.

## Test

### 1. Remove the asset

```bash
psi remove --db /tmp/psi-cli-remove-remove-asset-by-id/source <asset-id> --verbose --yes
```

Expected:
- Output includes `Successfully removed asset`.

## Check

### 2. Confirm the asset files are gone from storage

```bash
ls /tmp/psi-cli-remove-remove-asset-by-id/source/asset
ls /tmp/psi-cli-remove-remove-asset-by-id/source/display
ls /tmp/psi-cli-remove-remove-asset-by-id/source/thumb
```

Expected:
- None of those directories contain `<asset-id>` any more (the directories themselves may exist but be empty).

---

### 3. Confirm the database listing no longer shows the asset

```bash
psi list --db /tmp/psi-cli-remove-remove-asset-by-id/source
```

Expected:
- `<asset-id>` does not appear.

---

### 4. Verify the database

```bash
psi verify --db /tmp/psi-cli-remove-remove-asset-by-id/source
```

Expected:
- Verification completes without errors.
- `Modified:` reports `0` and `Removed:` reports `0` (because the merkle tree has also been updated).
