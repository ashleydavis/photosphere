# Plan: Non-interactive mode + smoke tests for secrets and dbs commands

## Context

The `secrets` and `dbs` CLI commands are mostly interactive (use clack prompts). Only a few commands support `--yes` for non-interactive use. The smoke tests can't test interactive commands, so coverage is poor. We need to:
1. Add `--yes` (+ value-passing options) to all commands that lack it
2. Add smoke tests for all `secrets` commands (except send/receive — covered in LAN share tests)
3. Add smoke test for `dbs edit` (the only missing dbs test besides send/receive)

## Part 1: Add `--yes` support to CLI commands

### `secrets view <name>` — apps/cli/src/cmd/secrets.ts
- Add `.option('--yes', 'Skip confirmation prompt')`
- Skip the "Reveal?" confirmation when `--yes` is passed
- Pattern: `cmdOptions: { yes?: boolean }` as second param

### `secrets delete <name>` — apps/cli/src/cmd/secrets.ts
- Add `.option('--yes', 'Skip confirmation prompt')`
- Skip the "Delete?" confirmation when `--yes` is passed

### `secrets add` — apps/cli/src/cmd/secrets.ts
- Add `.option('--yes', 'Skip prompts')`, `.option('--name <name>', ...)`, `.option('--type <type>', ...)`, `.option('--value <value>', ...)`
- When `--yes` + all three options provided: skip prompts, validate, write directly
- Validate type is in SECRET_TYPES

### `secrets edit <name>` — apps/cli/src/cmd/secrets.ts
- Add `.option('--yes', 'Skip prompts')`, `.option('--value <value>', 'New value')`
- When `--yes` + `--value` provided: update without prompting

### `secrets import` — apps/cli/src/cmd/secrets.ts
- Add `.option('--yes', 'Skip prompts')`, `.option('--private-key <path>', ...)`, `.option('--public-key <path>', ...)`, `.option('--key-name <name>', ...)`
- When `--yes` + `--private-key` provided: skip prompts. Auto-detect public key as `{path}.pub` if `--public-key` not provided. Default key name from filename if `--key-name` not given.

### `dbs add` — apps/cli/src/cmd/dbs.ts
- Add `.option('--yes', 'Skip prompts')`, `.option('--name <name>', ...)`, `.option('--description <desc>', ...)`, `.option('--path <path>', ...)`, `.option('--s3-cred-id <id>', ...)`, `.option('--encryption-key-id <id>', ...)`, `.option('--geocoding-key-id <id>', ...)`
- When `--yes` + `--name` + `--path` provided: skip prompts, use provided values

### `dbs edit <name>` — apps/cli/src/cmd/dbs.ts
- Add `.option('--yes', 'Skip prompts')`, `.option('--new-name <name>', ...)`, `.option('--description <desc>', ...)`, `.option('--path <path>', ...)`, `.option('--s3-cred-id <id>', ...)`, `.option('--encryption-key-id <id>', ...)`, `.option('--geocoding-key-id <id>', ...)`
- When `--yes`: use options if provided, keep existing values for unprovided fields

## Part 2: Smoke tests

All tests go in `apps/cli/smoke-tests.sh`. New test functions + entries in TEST_TABLE.

### secrets tests (skip send/receive):
1. **secrets-list-empty** — Empty vault shows "No secrets" message
2. **secrets-add** — `secrets add --yes --name "test-secret" --type plain --value "hello"` then verify with `secrets list`
3. **secrets-view** — Seed a secret, `secrets view <name> --yes`, verify output contains name/type/value
4. **secrets-edit** — Seed a secret, `secrets edit <name> --yes --value "updated"`, then `secrets view --yes` to verify
5. **secrets-delete** — Seed two secrets, `secrets delete <name> --yes`, verify one remains
6. **secrets-import** — Generate a PEM key pair in tmp dir, `secrets import --yes --private-key <path>`, verify imported via `secrets list`

### dbs tests:
7. **dbs-edit** — Seed a database entry, `dbs edit <name> --yes --new-name "renamed-db"`, then `dbs list` to verify rename
8. **dbs-add-cli** — `dbs add --yes --name "cli-db" --path "/tmp/cli-db"`, then `dbs list` to verify

## Files to modify
- `apps/cli/src/cmd/secrets.ts` — add `--yes` + options to add, view, edit, delete, import
- `apps/cli/src/cmd/dbs.ts` — add `--yes` + options to add, edit
- `apps/cli/smoke-tests.sh` — add test functions + TEST_TABLE entries

## Verification
- `bun run compile` from root to check TypeScript compiles
- Run the specific new smoke tests (or full suite) from `apps/cli/`
