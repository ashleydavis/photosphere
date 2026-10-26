# CLI Manual Test: Info

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `info` shows details of a media file on disk, and the database record of an asset looked up by ID.

## Prep

Move into the CLI source directory, clean up any previous test run, create a database, add a file and read its asset ID:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
bun run start -- init --db /tmp/psi-test/source --yes
bun run start -- add ../../test/test.jpg --db /tmp/psi-test/source --yes
ls /tmp/psi-test/source/asset
```

Expected:
- The file is added, and `ls` lists one UUID. Use it as `<asset-id>` below.

## Test

### 1. Info on a file on disk

```bash
bun run start -- info ../../test/test.jpg --yes
```

Expected:
- Output shows the file's type (`image/jpeg`), its dimensions (2560×1920) and its EXIF date, 27 May 2025.

---

### 2. Info on an asset by ID

```bash
bun run start -- info <asset-id> --db /tmp/psi-test/source --yes
```

Expected:
- Output shows the asset's database record, with `test.jpg` as its file name.

---

### 3. Info on a file that does not exist

```bash
bun run start -- info ../../test/no-such-file.jpg --yes
```

Expected:
- The command exits with a non-zero status and says the file was not found.

## Check

The output of steps 1 to 3 is the check.
