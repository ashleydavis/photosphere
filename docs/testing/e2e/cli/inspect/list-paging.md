# CLI Manual Test: List More Than One Page

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `list` splits a database with more files than the page size into pages and shows every file once.

## Prep

Move into the CLI source directory, clean up any previous test run and copy the 50-asset fixture to a working directory:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test
cp -r ../../test/dbs/50-assets /tmp/psi-test/db
bun run start -- summary --db /tmp/psi-test/db --yes
```

Expected:
- `Files imported:` reports the number of assets in the fixture. Note it.

## Test

### 1. List with a page size of 20

```bash
bun run start -- list --db /tmp/psi-test/db --page-size 20 --yes
```

Expected:
- The output has `--- Page 1 ---`, `--- Page 2 ---` and `--- Page 3 ---` headings, and no others.
- It ends with `Displayed <n> files total`, where `<n>` is the count from the prep.

## Check

### 2. Count the files shown

```bash
bun run start -- list --db /tmp/psi-test/db --page-size 20 --yes | grep -cE '^[0-9a-f-]{36} '
bun run start -- list --db /tmp/psi-test/db --page-size 20 --yes | grep -oE '^[0-9a-f-]{36}' | sort | uniq -d
```

Expected:
- The first command prints the count from the prep.
- The second prints nothing: no file is shown twice.
