# CLI S3 Tests

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Manual test scripts for databases stored on S3, run against a local MinIO server.

## Tests

- [s3-database.md](s3-database.md) - Create, add to, list and verify a database on S3
- [s3-replicate-and-sync.md](s3-replicate-and-sync.md) - Replicate a local database to S3 and sync changes both ways
