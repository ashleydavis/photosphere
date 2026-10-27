# CLI Manual Test: Resolve Database by Path

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that passing `--db <path>` resolves to the matching entry in
`databases.toml` and auto-loads the linked encryption key.

## Prep

From the repo root, build the CLI, put it on the PATH, point the CLI at empty config and vault directories, initialise an encrypted database with a generated key, add a file, republish the key under a shared id in the same `vault.json`, and register the database with that shared id:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-dbs-resolve-by-path
mkdir -p /tmp/psi-cli-dbs-resolve-by-path/config /tmp/psi-cli-dbs-resolve-by-path/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-dbs-resolve-by-path/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-cli-dbs-resolve-by-path/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
psi init --db /tmp/psi-cli-dbs-resolve-by-path/db --key dbs-path-enc-key --generate-key --yes
psi add test/test.png --db /tmp/psi-cli-dbs-resolve-by-path/db --key dbs-path-enc-key --yes
jq -c '. + {"enc00002":{"name":"enc00002","type":"encryption-key","value":.["dbs-path-enc-key"].value}}' \
    /tmp/psi-cli-dbs-resolve-by-path/vault/vault.json > /tmp/psi-cli-dbs-resolve-by-path/vault/vault.json.new
mv /tmp/psi-cli-dbs-resolve-by-path/vault/vault.json.new /tmp/psi-cli-dbs-resolve-by-path/vault/vault.json
cat > /tmp/psi-cli-dbs-resolve-by-path/config/databases.toml <<'TOML'
recent_database_names = []

[[databases]]
name = "resolve-path-db"
description = ""
path = "/tmp/psi-cli-dbs-resolve-by-path/db"
encryption_key = "enc00002"
TOML
```

Expected:
- The database is initialised and the asset is added.
- `/tmp/psi-cli-dbs-resolve-by-path/vault/vault.json` holds both a `dbs-path-enc-key` key and an `enc00002` key.

## Test

### 1. Run `summary` by path

```bash
psi summary --db /tmp/psi-cli-dbs-resolve-by-path/db --yes
```

Expected:
- The command exits successfully (the encryption key was auto-resolved through `databases.toml`).
- The summary output reflects the one previously-added asset (`Files imported: 1`).

## Check

The summary output in step 1 is the check.
