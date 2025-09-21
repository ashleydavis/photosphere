# Integration Tests

This directory contains integration tests that require external services or special setup.

## CloudStorage Tests

The CloudStorage tests (`cloud-storage.test.ts`) require:
- AWS credentials 
- S3 bucket access
- Network connectivity

These tests are **not** included in the regular test suite (`bun run test`) to avoid failures when AWS credentials are not available.

## Running Integration Tests

```bash
# CloudStorage tests
cd packages/storage
./run-cloud-storage-tests.sh

# Or directly:
bun test integration-tests/cloud-storage.test.ts
```

See `CLOUD_STORAGE_TESTS.md` for detailed setup instructions.

## Why Separate?

Integration tests are separated from unit tests because they:
- Require external dependencies (AWS, databases, etc.)
- May have costs associated (S3 operations)
- Need special configuration/credentials
- Take longer to run
- May not be available in all environments (CI/CD, local dev)

This ensures that `bun run test` always works for regular development without requiring complex setup.