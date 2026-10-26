# CLI Manual Test: Export Display and Thumbnail Versions

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `export --type display` and `export --type thumb` write the smaller versions of an asset, not the original.

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
- The file is added, and `ls` lists one UUID. Use it as `<asset-id>` below.

## Test

### 1. Export the display version

```bash
bun run start -- export --db /tmp/psi-test/source <asset-id> /tmp/psi-test/exports/display.jpg --type display --yes
```

Expected:
- Output contains `Successfully exported` and names the display version.

---

### 2. Export the thumbnail version

```bash
bun run start -- export --db /tmp/psi-test/source <asset-id> /tmp/psi-test/exports/thumb.jpg --type thumb --yes
```

Expected:
- Output contains `Successfully exported` and names the thumbnail version.

## Check

### 3. Confirm the exports are the stored display and thumbnail files

```bash
ls -l ../../test/test.jpg /tmp/psi-test/exports/
cmp /tmp/psi-test/exports/display.jpg /tmp/psi-test/source/display/<asset-id>
cmp /tmp/psi-test/exports/thumb.jpg /tmp/psi-test/source/thumb/<asset-id>
bun run start -- info /tmp/psi-test/exports/display.jpg /tmp/psi-test/exports/thumb.jpg --yes
```

Expected:
- Both exports exist, and each is smaller than the 2,049,800-byte original.
- Both `cmp` commands print nothing.
- `info` shows the thumbnail with smaller dimensions than the display version, and both smaller than the original 2560×1920.
