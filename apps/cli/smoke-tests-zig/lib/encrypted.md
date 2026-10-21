# encrypted.sh

Helpers shared by the encrypted database smoke tests of the Zig CLI (the tests under `apps/cli/smoke-tests-zig/` whose names start `encrypted-`, `encrypt-` or `decrypt-`, apart from the two key-not-found tests, which need none of them). They check whether a database's stored assets are encrypted and look up an asset's ID by its file name.

## Use

It is sourced, never run, after `common.sh`, which provides `log_error`, `log_success` and `get_zig_cli_command`:

```bash
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/encrypted.sh"
```

Find the tests that source it with `grep -l 'lib/encrypted.sh' apps/cli/smoke-tests-zig/*/test.sh`.

## Functions

- `read_magic_tag <file>`: prints the first 4 bytes of the file as ASCII. An encrypted asset starts with `PSEN`.
- `assert_database_assets_encrypted <db_dir>`: returns 0 when the first file under `<db_dir>/asset` starts with `PSEN`. Returns 1, with the reason logged, when it does not or when there is no asset directory or asset file.
- `assert_database_assets_plain <db_dir>`: returns 0 when the first file under `<db_dir>/asset` does not start with `PSEN`. Returns 1, with the reason logged, when it does or when there is no asset directory or asset file.
- `get_asset_id_for_filename <db_dir> <key> <filename>`: runs the Zig CLI's `psi list` on the database (with `--key <key>` unless the key is empty) and prints the asset ID on the line that names the file. Returns 1, with the list output printed, when the list fails or names no such file.

The assertions return rather than exit, so a test fails itself with `|| test_failed "<name>"`.
