# CLI Manual Test: Info

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `info` shows details of a media file on disk, and the database record of an asset looked up by ID.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run, point the CLI at an empty config directory, create a database, add a file and read its asset ID:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-info-info
mkdir -p /tmp/psi-cli-info-info/config
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-info-info/config
psi init --db /tmp/psi-cli-info-info/source --yes
psi add test/test.jpg --db /tmp/psi-cli-info-info/source --yes
ls /tmp/psi-cli-info-info/source/asset
```

Expected:
- The file is added, and `ls` lists one UUID. Use it as `<asset-id>` below.

## Test

### 1. Info on a file on disk

```bash
psi info test/test.jpg --yes
```

Expected:
- Output shows the file's type (`image/jpeg`), its dimensions (2560×1920) and its EXIF date, 27 May 2025.

---

### 2. Info on an asset by ID

```bash
psi info <asset-id> --db /tmp/psi-cli-info-info/source --yes
```

Expected:
- Output shows the asset's database record, with `test.jpg` as its file name.

---

### 3. Info on a file that does not exist

```bash
psi info test/no-such-file.jpg --yes
```

Expected:
- The command exits with a non-zero status and says the file was not found.

## Check

The output of steps 1 to 3 is the check.
