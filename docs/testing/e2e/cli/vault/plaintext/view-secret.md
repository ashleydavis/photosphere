# CLI Manual Test: View a Plaintext Vault Secret

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `secrets view --yes` prints the full secret value.

## Prep

From the repo root, build the CLI, put it on the PATH and point the CLI at empty config and vault directories, then seed a secret:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-vault-plaintext-view-secret
mkdir -p /tmp/psi-cli-vault-plaintext-view-secret/config /tmp/psi-cli-vault-plaintext-view-secret/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-vault-plaintext-view-secret/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-cli-vault-plaintext-view-secret/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
cat > /tmp/psi-cli-vault-plaintext-view-secret/vault/vault.json <<'JSON'
{"view-secret":{"name":"view-secret","type":"plain","value":"my-secret-value"}}
JSON
```

Expected: no output.

## Test

### 1. View the secret

```bash
psi secrets view --name view-secret --yes
```

Expected output contains all of:
- `view-secret` (the name).
- `plain` (the type).
- `my-secret-value` (the value).

## Check

The view output in step 1 is the check.
