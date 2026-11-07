# CLI Manual Test: Export Display and Thumbnail Versions

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `export --type display` and `export --type thumb` write the smaller versions of an asset, not the original.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run, create a database, add a file, read its asset ID and make the export directory:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-inspect-export-display-and-thumb
psi init --db /tmp/psi-cli-inspect-export-display-and-thumb/source --yes
psi add test/test.jpg --db /tmp/psi-cli-inspect-export-display-and-thumb/source --yes
ls /tmp/psi-cli-inspect-export-display-and-thumb/source/asset
mkdir -p /tmp/psi-cli-inspect-export-display-and-thumb/exports
```

Expected:
- The file is added, and `ls` lists one UUID. Use it as `<asset-id>` below.

## Test

### 1. Export the display version

```bash
psi export --db /tmp/psi-cli-inspect-export-display-and-thumb/source <asset-id> /tmp/psi-cli-inspect-export-display-and-thumb/exports/display.jpg --type display --yes
```

Expected:
- Output contains `Successfully exported` and names the display version.

---

### 2. Export the thumbnail version

```bash
psi export --db /tmp/psi-cli-inspect-export-display-and-thumb/source <asset-id> /tmp/psi-cli-inspect-export-display-and-thumb/exports/thumb.jpg --type thumb --yes
```

Expected:
- Output contains `Successfully exported` and names the thumbnail version.

## Check

### 3. Confirm the exports are the stored display and thumbnail files

```bash
ls -l test/test.jpg /tmp/psi-cli-inspect-export-display-and-thumb/exports/
cmp /tmp/psi-cli-inspect-export-display-and-thumb/exports/display.jpg /tmp/psi-cli-inspect-export-display-and-thumb/source/display/<asset-id>
cmp /tmp/psi-cli-inspect-export-display-and-thumb/exports/thumb.jpg /tmp/psi-cli-inspect-export-display-and-thumb/source/thumb/<asset-id>
psi info /tmp/psi-cli-inspect-export-display-and-thumb/exports/display.jpg /tmp/psi-cli-inspect-export-display-and-thumb/exports/thumb.jpg --yes
```

Expected:
- Both exports exist, and each is smaller than the 2,049,800-byte original.
- Both `cmp` commands print nothing.
- `info` shows the thumbnail with smaller dimensions than the display version, and both smaller than the original 2560×1920.
