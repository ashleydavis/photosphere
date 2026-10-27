# CLI Manual Test: `dbs add` via CLI Flags

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `dbs add` can register a database non-interactively using `--name`
and `--path`.

## Prep

From the repo root, build the CLI, put it on the PATH and point the CLI at an empty config directory:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-dbs-add-via-flags
mkdir -p /tmp/psi-cli-dbs-add-via-flags/config
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-dbs-add-via-flags/config
```

Expected: no output.

## Test

### 1. Add a database entry via CLI flags

```bash
psi dbs add --yes --name cli-db --path /tmp/psi-cli-dbs-add-via-flags/cli-db-path
```

Expected:
- The command exits successfully.

## Check

### 2. Confirm the new entry is listed

```bash
psi dbs list
```

Expected:
- Output contains `cli-db`.
- Output contains `/tmp/psi-cli-dbs-add-via-flags/cli-db-path`.
