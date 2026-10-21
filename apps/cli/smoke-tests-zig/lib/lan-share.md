# lan-share.sh

Helpers shared by the LAN share smoke tests of the Zig CLI: the tests under `apps/cli/smoke-tests-zig/` named `lan-share-*`. They pair a sender and a receiver on this machine through `psi dbs send`/`receive` and `psi secrets send`/`receive`, each side with a vault and config of its own, and check what arrives. The `*-ts-to-zig` and `*-zig-to-ts` tests run one side in the TypeScript CLI.

## Use

It is sourced, never run, after `common.sh`:

```bash
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/lan-share.sh"
```

Find the tests that source it with `grep -l 'lib/lan-share.sh' apps/cli/smoke-tests-zig/*/test.sh`.

Sourcing it does more than define functions:

- It points `SENDER_VAULT_DIR`, `SENDER_CONFIG_DIR`, `RECEIVER_VAULT_DIR` and `RECEIVER_CONFIG_DIR` at directories under the test's `TEST_TMP_DIR` and creates the two receiver directories.
- It sets `ZIG_CLI_CMD` (the Zig CLI), `TS_CLI_CMD` (the TypeScript CLI, compiled under `--binary`) and `SENDER_CLI_CMD` and `RECEIVER_CLI_CMD`, both the Zig CLI. An interop test sets one of the last two to `TS_CLI_CMD`.
- It sets the test's exit trap to `lan_share_exit; cleanup_and_show_summary`, so a LAN share test sets none of its own.
- It creates `TEST_PID_FILE` (`$TEST_TMP_DIR/test-pids`) empty. Every process a test starts is recorded there and in `TEST_PIDS`, and is stopped by pid through `kill_process_tree`, never by name.
- On macOS, where there is no `sha256sum`, it defines one over `shasum -a 256`.

Pairing codes come from `allocate_pairing_code` (`scripts/lib/test-lib.sh`), so a test cannot pair with a receiver belonging to another run on the machine. Vault secrets and the database list are seeded with `common.sh`'s `seed_vault_secret` and `seed_databases_config`, with `PHOTOSPHERE_VAULT_DIR` or `PHOTOSPHERE_CONFIG_DIR` set to the side's directory in front of the call.

## Functions

- `use_test_temp_dir <dir>`: sets the four sender and receiver directory variables to `<dir>/sender-vault`, `<dir>/sender-config`, `<dir>/receiver-vault` and `<dir>/receiver-config`. Called once by the library on `TEST_TMP_DIR`.
- `kill_proc <pid>`: kills the process and its descendants and reaps it.
- `track_test_pid <pid>`: records a pid in `TEST_PIDS` and in `TEST_PID_FILE`.
- `run_cli_tracked <log_file> <command...>`: runs the command in the background with its output in `<log_file>`, records its pid, waits for it and returns its exit code.
- `kill_test_pids`: kills every pid in `TEST_PIDS` with its descendants and clears `TEST_PIDS` and `TEST_PID_FILE`.
- `test_cleanup`: kills the receiver in `RECEIVER_PID`, then everything `kill_test_pids` kills.
- `lan_share_exit`: the exit trap. Kills every pid in `TEST_PID_FILE`, runs `test_cleanup`, kills any job still running and returns the exit code the test exited with, which `cleanup_and_show_summary` then reports.
- `merge_vault_secret <vault_dir> <secret_json>`: merges a `{name, type, value}` object into `<vault_dir>/vault.json` under its name. Fails the test when the vault file is not valid JSON.
- `seed_vault_secret_from_file <vault_dir> <name> <type> <value_file>`: seeds a secret whose value is the file's exact bytes, which is how a multi-line PEM gets in.
- `count_vault_secrets <vault_dir>`: prints how many secrets `<vault_dir>/vault.json` holds, 0 when it is absent.
- `start_receiver_with_code <dbs|secrets> <log_file> <code>`: starts `RECEIVER_CLI_CMD <dbs|secrets> receive` with the receiver's vault and config and the given pairing code, sets `RECEIVER_PID` and waits for "Waiting for sender". Fails the test when the receiver exits first or is not ready within 60 seconds.
- `wait_for_receiver_exit`: waits for the receiver in `RECEIVER_PID` to exit, so its vault and config are complete before they are read.
- `capture_receiver_broadcast <code_hash> <log_file>`: runs `test/udp-listen.ts` in the background until it has captured the running receiver's discovery broadcast for that code hash, or until the receiver is no longer alive, and prints what it captured on stdout (`PSIE_RECV:{port}:{codeHash}:{fingerprint}`, or nothing). Its stderr goes to `<log_file>.stderr`. It has no time limit of its own; the runner's per-test timeout ends a receiver that stays alive and never broadcasts.
- `share_database_and_check`: seeds the sender with S3 credentials, an encryption key and a database entry, shares the database from `SENDER_CLI_CMD` to `RECEIVER_CLI_CMD`, and fails the test unless both sides report success, the receiver's vault holds a secret and its `databases.toml` holds the entry.
- `share_secret_and_check`: seeds the sender with an API key, shares it from `SENDER_CLI_CMD` to `RECEIVER_CLI_CMD`, and fails the test unless both sides report success and the receiver's vault holds a secret.
