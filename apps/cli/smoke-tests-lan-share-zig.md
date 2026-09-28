# LAN Share Smoke Test (Zig)

`smoke-tests-lan-share-zig.sh` is the Zig counterpart of `smoke-tests-lan-share.sh`. It runs every test of the TypeScript suite with both the sender and the receiver in the Zig port of psi (`apps/cli-zig`), then adds interop tests that pair the Zig CLI with the TypeScript CLI in both directions.

## Prerequisites

- The Zig CLI, built with `zig build` in `apps/cli-zig` (the script fails at once if `../cli-zig/zig-out/bin/psi` is missing).
- `bun install` from the repo root, for the TypeScript CLI in the interop tests and the databases config helper.
- `jq`, `curl` and `openssl`, which the TypeScript suite also uses.

## Usage

From the repo root:

```bash
bun run test:cli:lan-share:zig
```

### Options

| Option | Description |
|--------|-------------|
| `-b`, `--binary` | Run the TypeScript side of the interop tests from the compiled binary (`./bin/x64/linux/psi`) instead of `bun run start` |

## Tests

The same tests as the TypeScript suite, in the same order, with both sides in the Zig CLI:

1. `test_share_database`: a database and its secrets are shared and imported.
2. `test_share_secret`: a single secret is shared and imported.
3. `test_wrong_pairing_code`: a sender with the wrong code is rejected and nothing is imported.
4. `test_share_database_no_secrets`: a database with no secrets is shared.
5. `test_receiver_cancel`: a receiver exits cleanly on SIGINT.
6. `test_rogue_receiver_rejected`: a wrong certificate pin and plain HTTP are refused.
7. `test_cert_fingerprint_matches_broadcast`: the broadcast fingerprint matches the TLS certificate.

Interop tests, which rerun a share with one side in the TypeScript CLI:

8. `test_share_database_ts_to_zig`: TypeScript sender, Zig receiver.
9. `test_share_database_zig_to_ts`: Zig sender, TypeScript receiver.
10. `test_share_secret_ts_to_zig`: TypeScript sender, Zig receiver.
11. `test_share_secret_zig_to_ts`: Zig sender, TypeScript receiver.

Each test runs in its own temporary directory from `scripts/lib/test-lib.sh`, and every process it starts is recorded and stopped with `kill_process_tree`.

## CI

The Release workflow runs this suite on Linux in the `zig-smoke-tests` job, like the TypeScript `lan-share-smoke-test` job.
