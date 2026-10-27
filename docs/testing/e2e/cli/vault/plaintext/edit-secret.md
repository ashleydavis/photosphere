# CLI Manual Test: Edit a Plaintext Vault Secret

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that `secrets edit` can update the value of a secret and rename it.

## Prep

From the repo root, build the CLI, put it on the PATH and point the CLI at empty config and vault directories, then seed a secret:

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-vault-plaintext-edit-secret
mkdir -p /tmp/psi-cli-vault-plaintext-edit-secret/config /tmp/psi-cli-vault-plaintext-edit-secret/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-vault-plaintext-edit-secret/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-cli-vault-plaintext-edit-secret/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
cat > /tmp/psi-cli-vault-plaintext-edit-secret/vault/vault.json <<'JSON'
{"edit-secret":{"name":"edit-secret","type":"plain","value":"original-value"}}
JSON
```

Expected: no output.

## Test

### 1. Update the value

```bash
psi secrets edit --name edit-secret --yes --value updated-value
```

Expected:
- The command exits successfully.

---

### 2. Confirm the value updated

```bash
psi secrets view --name edit-secret --yes
```

Expected:
- Output contains `updated-value`.

---

### 3. Rename the secret

```bash
psi secrets edit --name edit-secret --yes --new-name renamed-secret
```

Expected:
- The command exits successfully.

## Check

### 4. Confirm the rename

```bash
psi secrets list
```

Expected:
- Output contains `renamed-secret`.
- Output does not contain `edit-secret`.
