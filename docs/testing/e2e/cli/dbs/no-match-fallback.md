# CLI Manual Test: No-Match Fallback

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that when `databases.toml` has no entry matching the supplied `--db`
argument, the CLI falls back to the existing manual config flow without
errors.

## Prep

Move into the CLI source directory, point the CLI at empty config and vault directories, create a plain (unencrypted) database, add a file and make sure `databases.toml` has no matching entry:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test/config /tmp/psi-test/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-test/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-test/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
bun run start -- init --db /tmp/psi-test/db --yes
bun run start -- add ../../test/test.png --db /tmp/psi-test/db --yes
printf 'recent_database_names = []\n' > /tmp/psi-test/config/databases.toml
```

Expected:
- The database is initialised and the asset is added.

## Test

### 1. Run `summary` against the unregistered database

```bash
bun run start -- summary --db /tmp/psi-test/db --yes
```

Expected:
- The command exits successfully even though `databases.toml` does not name this database.
- The summary output reflects the previously-added asset.

## Check

The summary output in step 1 is the check.
