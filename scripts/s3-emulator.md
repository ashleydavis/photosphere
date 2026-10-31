# s3-emulator.sh

Starts and stops a local MinIO server, so an S3 test needs no account and no credentials. The pinned MinIO release is downloaded once into a git-ignored cache in the repo. The server takes a free port and speaks plain HTTP, and its bucket is seeded with two small prefixes for the S3 browser to list.

Invoke from the repo root:

- `bun run s3-emulator start <state-dir>`: empties `<state-dir>`, starts a server whose data lives there and writes `<state-dir>/env`, which exports `S3_EMULATOR_PORT`, `S3_EMULATOR_BUCKET`, `S3_EMULATOR_ACCESS_KEY` and `S3_EMULATOR_SECRET_KEY`.
- `bun run s3-emulator stop <state-dir>`: stops the server recorded in `<state-dir>`. It never fails, so it is safe in a trap.

Manual tests use it through [start-minio](start-minio.md).
