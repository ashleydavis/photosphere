# start-minio.sh

Starts a local MinIO server with a fresh bucket for a manual test, creates the test's database in it and sets the CLI up to use it with its own config and vault, at an address a phone on the same network can reach. The server itself is run by [s3-emulator.sh](s3-emulator.md), and [stop-minio](stop-minio.md) stops it. The guide for using it in a test is [MinIO for the manual tests](../docs/testing/e2e/minio.md).

Invoke from the repo root: `bun run start-minio -- <name> [--from <fixture>] [--add <path>] [--encrypt] [--key <pem file>] [--empty] [--lan-ip <address>]`

Arguments:

- `<name>`: the test's name for its database. It names the CLI entry, the credentials secret (`<name>-s3`), the generated key (`<name>-key`), the database's prefix in the bucket and the state directory `tmp/minio/<name>`.
- `--from <fixture>`: replicate the directory `test/dbs/<fixture>` into the bucket. Cannot be combined with `--encrypt` or `--key`.
- `--add <path>`: after creating the database, add this file or directory, relative to the repo root.
- `--encrypt`: generate a key as the secret `<name>-key`, encrypt the database with it and attach it to the entry.
- `--key <pem file>`: import this 4096-bit RSA PEM and encrypt the database with it, without attaching it to the entry.
- `--empty`: create no database, only the bucket, the credentials and the entry.
- `--lan-ip <address>`: the address the phone reaches this machine by. Without it, the first address from `hostname -I` on Linux, or that of `en0` or `en1` on macOS.

It builds the CLI, empties and restarts the server for `<name>`, and writes `tmp/minio/<name>.env`, which a test sources to get `psi` on the PATH, the CLI config and vault, the bucket's credentials (`AWS_*`) and `S3_DB`, the database's `s3:` path. It prints the endpoint and keys for the phone.
