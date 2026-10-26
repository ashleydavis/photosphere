# CLI Manual Test: `vault list` Showing Shared Secrets

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test that secrets seeded with shared id names appear in `secrets list`.

## Prep

Move into the CLI source directory and point the CLI at empty config and vault directories, seed an S3 credential secret, then merge an API key secret into the same `vault.json` (every secret lives in one file, keyed by its name):

```bash
cd apps/cli/
rm -rf /tmp/psi-test
mkdir -p /tmp/psi-test/config /tmp/psi-test/vault
export PHOTOSPHERE_CONFIG_DIR=/tmp/psi-test/config
export PHOTOSPHERE_VAULT_DIR=/tmp/psi-test/vault
export PHOTOSPHERE_VAULT_TYPE=plaintext
cat > /tmp/psi-test/vault/vault.json <<'JSON'
{"s3test01":{"name":"s3test01","type":"s3-credentials","value":"{\"region\":\"us-east-1\",\"accessKeyId\":\"AKIATEST\",\"secretAccessKey\":\"secret123\",\"endpoint\":\"http://localhost:9000\"}"}}
JSON
jq -c '. + {"api00001":{"name":"api00001","type":"api-key","value":"AIzaFakeKey123"}}' \
    /tmp/psi-test/vault/vault.json > /tmp/psi-test/vault/vault.json.new
mv /tmp/psi-test/vault/vault.json.new /tmp/psi-test/vault/vault.json
```

Expected: no output.

## Test

### 1. List secrets

```bash
bun run start -- secrets list
```

Expected output contains both:
- `s3test01`.
- `api00001`.

## Check

The list output in step 1 is the check.
