# CLI Manual Test: `vault list` Showing Shared Secrets

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that secrets seeded with shared id names appear in `secrets list`.

## Prep

From the repo root, build the CLI, put it on the PATH and point the CLI at empty config and vault directories, seed an S3 credential secret, then merge an API key secret into the same `vault.json` (every secret lives in one file, keyed by its name):

```bash
zig build
export PATH="$PWD/zig-out/bin:$PATH"
rm -rf /tmp/psi-cli-vault-plaintext-list-shared
mkdir -p /tmp/psi-cli-vault-plaintext-list-shared/config /tmp/psi-cli-vault-plaintext-list-shared/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-cli-vault-plaintext-list-shared/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-cli-vault-plaintext-list-shared/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
cat > /tmp/psi-cli-vault-plaintext-list-shared/vault/vault.json <<'JSON'
{"s3test01":{"name":"s3test01","type":"s3-credentials","value":"{\"region\":\"us-east-1\",\"accessKeyId\":\"AKIATEST\",\"secretAccessKey\":\"secret123\",\"endpoint\":\"http://localhost:9000\"}"}}
JSON
jq -c '. + {"api00001":{"name":"api00001","type":"api-key","value":"AIzaFakeKey123"}}' \
    /tmp/psi-cli-vault-plaintext-list-shared/vault/vault.json > /tmp/psi-cli-vault-plaintext-list-shared/vault/vault.json.new
mv /tmp/psi-cli-vault-plaintext-list-shared/vault/vault.json.new /tmp/psi-cli-vault-plaintext-list-shared/vault/vault.json
```

Expected: no output.

## Test

### 1. List secrets

```bash
psi secrets list
```

Expected output contains both:
- `s3test01`.
- `api00001`.

## Check

The list output in step 1 is the check.
