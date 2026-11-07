# CLI Manual Test: List More Than One Page

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `list` splits a database with more files than the page size into pages and shows every file once.

## Prep

From the repo root, build the CLI, put it on the PATH, clean up any previous test run and copy the 50-asset fixture to a working directory:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-inspect-list-paging
mkdir -p /tmp/psi-cli-inspect-list-paging
cp -r test/dbs/50-assets /tmp/psi-cli-inspect-list-paging/db
psi summary --db /tmp/psi-cli-inspect-list-paging/db --yes
```

Expected:
- `Files imported:` reports the number of assets in the fixture. Note it.

## Test

### 1. List with a page size of 20

```bash
psi list --db /tmp/psi-cli-inspect-list-paging/db --page-size 20 --yes
```

Expected:
- The output has `--- Page 1 ---`, `--- Page 2 ---` and `--- Page 3 ---` headings, and no others.
- It ends with `Displayed <n> files total`, where `<n>` is the count from the prep.

## Check

### 2. Count the files shown

```bash
psi list --db /tmp/psi-cli-inspect-list-paging/db --page-size 20 --yes | grep -cE '^[0-9a-f-]{36} '
psi list --db /tmp/psi-cli-inspect-list-paging/db --page-size 20 --yes | grep -oE '^[0-9a-f-]{36}' | sort | uniq -d
```

Expected:
- The first command prints the count from the prep.
- The second prints nothing: no file is shown twice.
