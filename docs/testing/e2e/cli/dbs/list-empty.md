# CLI Manual Test: `dbs list` With No Entries

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `psi dbs list` shows an empty-state message when no databases are
configured.

Each `dbs` test isolates the user's `databases.toml` by overriding
`PHOTOSPHERE_CONFIG_DIR`. The smoke-test infrastructure does this with an
auto-cleared temp dir. Use the same approach below.

## Prep

From the repo root, build the CLI, put it on the PATH and point the CLI at an empty config directory:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-dbs-list-empty
mkdir -p /tmp/psi-cli-dbs-list-empty/config
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-dbs-list-empty/config
```

Expected:
- `/tmp/psi-cli-dbs-list-empty/config` exists and contains no `databases.toml` file.

## Test

### 1. List databases

```bash
psi dbs list
```

Expected:
- Output includes `No databases`.

## Check

The list output in step 1 is the check.
