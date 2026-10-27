# CLI Manual Test: No-Match Fallback

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that when `databases.toml` has no entry matching the supplied `--db`
argument, the CLI falls back to the existing manual config flow without
errors.

## Prep

From the repo root, build the CLI, put it on the PATH, point the CLI at empty config and vault directories, create a plain (unencrypted) database, add a file and make sure `databases.toml` has no matching entry:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-dbs-no-match-fallback
mkdir -p /tmp/psi-cli-dbs-no-match-fallback/config /tmp/psi-cli-dbs-no-match-fallback/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-dbs-no-match-fallback/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-cli-dbs-no-match-fallback/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
psi init --db /tmp/psi-cli-dbs-no-match-fallback/db --yes
psi add test/test.png --db /tmp/psi-cli-dbs-no-match-fallback/db --yes
printf 'recent_database_names = []\n' > /tmp/psi-cli-dbs-no-match-fallback/config/databases.toml
```

Expected:
- The database is initialised and the asset is added.

## Test

### 1. Run `summary` against the unregistered database

```bash
psi summary --db /tmp/psi-cli-dbs-no-match-fallback/db --yes
```

Expected:
- The command exits successfully even though `databases.toml` does not name this database.
- The summary output reflects the previously-added asset.

## Check

The summary output in step 1 is the check.
