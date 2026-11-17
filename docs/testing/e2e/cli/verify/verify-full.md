# CLI Manual Test: Full Verify

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `verify --full` performs a deeper integrity scan than the default
quick scan.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run, create a database and add a file:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-verify-verify-full
psi init --db /tmp/psi-cli-verify-verify-full/source --yes
psi add test/test.jpg --db /tmp/psi-cli-verify-verify-full/source --yes
```

Expected:
- Database created and the file is reported as added.

## Test

### 1. Run a quick verify

```bash
psi verify --db /tmp/psi-cli-verify-verify-full/source
```

Expected:
- Verification completes without errors.
- `New:`, `Modified:`, and `Removed:` all report `0`.

---

### 2. Run a full verify

```bash
psi verify --db /tmp/psi-cli-verify-verify-full/source --full
```

Expected:
- Verification completes without errors.
- `New:`, `Modified:`, and `Removed:` all report `0`.

---

### 3. Change the asset's content but keep its size and modification time

The quick verify hashes a file only when its size or modification time has changed, so this change is one only the full verify can find.

```bash
ASSET=/tmp/psi-cli-verify-verify-full/source/asset/$(ls /tmp/psi-cli-verify-verify-full/source/asset)
cp -p "$ASSET" /tmp/psi-cli-verify-verify-full/asset-original
printf 'XXXXXXXX' | dd of="$ASSET" bs=1 seek=100000 conv=notrunc 2>/dev/null
touch -r /tmp/psi-cli-verify-verify-full/asset-original "$ASSET"
cmp -s /tmp/psi-cli-verify-verify-full/asset-original "$ASSET" || echo "content differs"
```

Expected:
- It prints `content differs`.

## Check

### 4. Run a quick verify

```bash
psi verify --db /tmp/psi-cli-verify-verify-full/source
```

Expected:
- `Modified:` reports `0`: the quick verify does not hash a file whose size and modification time are unchanged.
- Output includes `Database verification passed - all files are intact`.

---

### 5. Run a full verify

```bash
psi verify --db /tmp/psi-cli-verify-verify-full/source --full
```

Expected:
- `Modified:` reports `1`, and `Modified files:` lists `asset/<id>`, where `<id>` is the name of the one file in `/tmp/psi-cli-verify-verify-full/source/asset`.
- The command reports that verification found issues.
