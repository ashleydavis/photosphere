# common.sh

The library every Zig CLI smoke test sources. It takes no arguments and runs nothing of its own beyond setting up the test's environment.

It points `TEST_TMP_DIR`, `PHOTOSPHERE_TMP_DIR`, `PHOTOSPHERE_CACHE_DIR`, `PHOTOSPHERE_VAULT_DIR` and `PHOTOSPHERE_CONFIG_DIR` at the test's own directory, so a test never shares a database, a vault or a config with another run. It defines, among others:

- `get_zig_cli_command`: the Zig `psi` the runner built into `PHOTOSPHERE_ZIG_CLI_DIR`.
- `invoke_command <description> <command> [expected exit code] [output variable]`: runs a command, prints its output and fails the test on an unexpected exit code.
- `verify_database <database> [verify arguments...]`: runs `psi verify` on a database and fails the test unless it passes.
- `check_merkle_tree_order <database> [description]`: fails the test unless `psi debug merkle-check` finds the leaves of the database's files tree in order.
- `seed_databases_config <json list>`: writes `databases.toml` with the given entries.
- `seed_vault_secret <name> <type> <value>`: adds a secret to the plaintext vault.
- `start_s3_emulator <state dir>` and `stop_s3_emulator <state dir>`: the local S3 server the S3 tests use.
- `create_db_with_5_files <db path>`: the standard five-file database, copied from the run's prebuilt one when there is one.
