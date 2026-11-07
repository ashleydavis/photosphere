# CLI Manual Test: `secrets clear --yes` Removes All

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `secrets clear --yes` empties the vault entirely.

## Prep

From the repo root, build the CLI, put it on the PATH and point the CLI at empty config and vault directories, then seed two secrets:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-vault-plaintext-clear
mkdir -p /tmp/psi-cli-vault-plaintext-clear/config /tmp/psi-cli-vault-plaintext-clear/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-vault-plaintext-clear/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-cli-vault-plaintext-clear/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
cat > /tmp/psi-cli-vault-plaintext-clear/vault/vault.json <<'JSON'
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
psi secrets clear --yes
```

Expected:
- The command exits successfully.

## Check

### 2. Confirm the vault is empty

```bash
psi secrets list
```

Expected:
- Output contains `No secrets`.
- Output does not contain `clear-secret-one` or `clear-secret-two`.
