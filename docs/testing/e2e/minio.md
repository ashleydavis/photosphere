# MinIO for the Manual Tests

The manual tests that need S3 run against MinIO, a local S3 server on your development machine, rather than a real bucket. It needs no account, no credentials of your own and no clean-up, and every test starts with a fresh, empty bucket.

## Install

Nothing to install by hand. The first `bun run start-minio` downloads the pinned MinIO release into a git-ignored cache in the repo and reuses it after that. It needs:

- `bun install` and `mise install` already done at the repo root, as for anything else in the repo.
- `curl` and `jq` on the PATH.
- Internet access the first time, for the download.

## Start a fresh bucket for a test

From the repo root:

```bash
bun run start-minio -- <name> [options]
source tmp/minio/<name>.env
```

`start-minio` builds the CLI, starts a new MinIO server with an empty bucket, creates the database the test asks for in it and registers it with the CLI as the entry `<name>`, with the credentials secret `<name>-s3`. Running `start-minio` again with the same name throws the old bucket away and starts over.

The options say what the database starts with:

- none: an empty database.
- `--from <fixture>`: a copy of a test database from `test/dbs`, such as `50-assets` (60 photos) or `1-asset`.
- `--add <path>`: an empty database with the file or directory at `<path>` (relative to the repo root) added to it.
- `--encrypt`: the database is encrypted with a key generated for it, stored as the secret `<name>-key` and attached to the entry.
- `--key <pem file>`: the database is encrypted with that 4096-bit RSA key, which is not attached to the entry.
- `--empty`: no database at all, only the bucket, the credentials and the entry.
- `--lan-ip <address>`: the address the phone uses to reach this machine, when the one worked out automatically is wrong.

`source` sets up that terminal for the CLI: `psi` on the PATH, the test's own CLI config and vault (your keychain and database list are not touched), the credentials for the bucket, and `$S3_DB`, the database's `s3:` path. Run the test's later CLI commands in the same terminal.

`start-minio` finishes by printing the endpoint, region, access key and secret key, for a test that has you type them into the phone.

## Get the database onto the phone

```bash
psi dbs send --name <name> --yes
```

It prints a pairing code and waits. On the phone, go to the **Databases** page, choose **Receive database**, enter the code, and save. The entry arrives with its credentials (and its key, with `--encrypt`).

## Stop it

```bash
bun run stop-minio -- <name>
```

## The phone has to reach this machine

The credentials sent to the phone point at this machine's address on the local network, such as `http://192.168.1.20:41234`.

- A real phone must be on the same Wi-Fi as this machine.
- The Android emulator pool is on the local network, so it reaches the address too. The iOS simulator shares this machine's network.
- A firewall on this machine must let the port through. MinIO takes a free port each time, printed by `start-minio`.
- On Linux the address is the first one `hostname -I` prints, and on macOS the address of `en0` or `en1`. If that is not the one the phone can reach, pass the right one with `--lan-ip`.

The server speaks plain HTTP. That is expected: it lives only for the test and holds nothing real.

See [scripts/start-minio.md](../../../scripts/start-minio.md) for the script itself.
