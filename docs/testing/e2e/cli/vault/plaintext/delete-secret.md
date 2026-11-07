# CLI Manual Test: Delete a Plaintext Vault Secret

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `secrets remove --yes` deletes a secret while leaving the rest of
the vault intact.

## Prep

From the repo root, build the CLI, put it on the PATH and point the CLI at empty config and vault directories, then seed two secrets:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-vault-plaintext-delete-secret
mkdir -p /tmp/psi-cli-vault-plaintext-delete-secret/config /tmp/psi-cli-vault-plaintext-delete-secret/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-vault-plaintext-delete-secret/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-cli-vault-plaintext-delete-secret/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
cat > /tmp/psi-cli-vault-plaintext-delete-secret/vault/vault.json <<'JSON'
{
  "keep-secret": {"name":"keep-secret","type":"plain","value":"keep-me"},
  "delete-secret": {"name":"delete-secret","type":"plain","value":"delete-me"}
}
JSON
```

Expected: no output.

## Test

### 1. Delete one of them

```bash
psi secrets remove --name delete-secret --yes
```

Expected:
- The command exits successfully.

## Check

### 2. Confirm the list and the vault file

```bash
psi secrets list
jq 'keys' /tmp/psi-cli-vault-plaintext-delete-secret/vault/vault.json
```

Expected:
- The list contains `keep-secret` and does not contain `delete-secret`.
- `/tmp/psi-cli-vault-plaintext-delete-secret/vault/vault.json` no longer holds a `delete-secret` key, and still holds `keep-secret`.
