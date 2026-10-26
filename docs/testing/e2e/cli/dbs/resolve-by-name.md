# CLI Manual Test: Resolve Database by Name

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `--db <name>` resolves through `databases.toml` and auto-loads the
linked encryption key from the shared vault.

## Prep

Move into the CLI source directory, point the CLI at empty config and vault directories, initialise an encrypted database with a generated key, add a file, republish the key under a shared id in the same `vault.json`, and register the database with that shared id:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test/config /tmp/psi-test/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-test/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-test/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
bun run start -- init --db /tmp/psi-test/db --key dbs-enc-key --generate-key --yes
bun run start -- add ../../test/test.png --db /tmp/psi-test/db --key dbs-enc-key --yes
jq -c '. + {"enc00001":{"name":"enc00001","type":"encryption-key","value":.["dbs-enc-key"].value}}' \
    /tmp/psi-test/vault/vault.json > /tmp/psi-test/vault/vault.json.new
mv /tmp/psi-test/vault/vault.json.new /tmp/psi-test/vault/vault.json
cat > /tmp/psi-test/config/databases.toml <<'TOML'
recent_database_names = []

[[databases]]
name = "resolve-name-db"
description = ""
path = "/tmp/psi-test/db"
encryption_key = "enc00001"
TOML
```

Expected:
- The database is initialised and the asset is added.
- `/tmp/psi-test/vault/vault.json` holds both a `dbs-enc-key` key and an `enc00001` key.

## Test

### 1. Run `summary` by name

```bash
bun run start -- summary --db resolve-name-db --yes
```

Expected:
- The command exits successfully (the encryption key was auto-resolved through `databases.toml`).
- The summary output reflects the one previously-added asset (`Files imported: 1`).

## Check

The summary output in step 1 is the check.
