# CLI Manual Test: `secrets clear --yes` Removes All

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `secrets clear --yes` empties the vault entirely.

## Prep

Move into the CLI source directory and point the CLI at empty config and vault directories, then seed two secrets:

```bash
cd apps/cli/
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test/config /tmp/psi-test/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-test/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-test/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
cat > /tmp/psi-test/vault/vault.json <<'JSON'
{
  "clear-secret-one": {"name":"clear-secret-one","type":"plain","value":"value-one"},
  "clear-secret-two": {"name":"clear-secret-two","type":"plain","value":"value-two"}
}
JSON
```

Expected: no output.

## Test

### 1. Clear all secrets

```bash
bun run start -- secrets clear --yes
```

Expected:
- The command exits successfully.

## Check

### 2. Confirm the vault is empty

```bash
bun run start -- secrets list
```

Expected:
- Output contains `No secrets`.
- Output does not contain `clear-secret-one` or `clear-secret-two`.
