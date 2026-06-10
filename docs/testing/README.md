# Testing

Manual and automated test documentation for Photosphere.

## Running tests

Run all CLI smoke tests (from repo root):

```bash
bun run test:cli
```

Run a single CLI smoke test by number or name:

```bash
bun run test:cli -- 43
bun run test:cli -- replicate-partial
```

Run all unit tests:

```bash
bun run test
```

Run a single unit test by name or pattern:

```bash
bun run test -- <test-name-or-pattern>
```

Run performance benchmarks:

```bash
bun run perf
```

Capture desktop app screenshots headlessly (for UX review / docs):

```bash
bun run screenshots
```

## Manual testing

The manual end-to-end tests live under [e2e/](e2e/). Each test is a short markdown script with prerequisites, numbered steps, and expected results. They are split into:

- [e2e/cli/](e2e/cli/) - Tests for the `psi` CLI.
- [e2e/desktop/](e2e/desktop/) - Tests for the Photosphere desktop app.

Work through [e2e/CHECKLIST.md](e2e/CHECKLIST.md), which lists every test and tracks pass/fail status for the upcoming version.

### Running a manual test

- CLI tests: run the commands from `apps/cli/` (each test starts with `cd apps/cli/`), using `bun run start -- <command>`.
- Desktop tests: start the app from source with `bun run dev` (run from the repo root), then follow the on-screen steps. Some desktop tests also run CLI commands to set up or verify state.

### Use an isolated config and vault

By default the app reads and writes your real config at `~/.config/photosphere`, your system keychain, and any databases you normally use. To test against a throwaway environment that leaves your real setup untouched, set these environment variables before launching:

| Variable | Controls | Default |
|---|---|---|
| `PHOTOSPHERE_CONFIG_DIR` | Config dir (`desktop.toml`, `databases.toml`) | `~/.config/photosphere` |
| `PHOTOSPHERE_VAULT_DIR` | Secrets storage (plaintext mode only) | `~/.config/photosphere/vault` |
| `PHOTOSPHERE_VAULT_TYPE` | Vault backend: `plaintext` or `keychain` | `keychain` |
| `PHOTOSPHERE_LOG_DIR` | Log output | system temp |

Set `PHOTOSPHERE_VAULT_TYPE=plaintext` so secrets go to a directory instead of your system keychain.

Launch the desktop app with an isolated environment (run from the repo root):

```bash
TEST_DIR="/tmp/photosphere-isolated-$$"
mkdir -p "$TEST_DIR"/{config,vault,logs}

PHOTOSPHERE_CONFIG_DIR="$TEST_DIR/config" \
PHOTOSPHERE_VAULT_DIR="$TEST_DIR/vault" \
PHOTOSPHERE_VAULT_TYPE=plaintext \
PHOTOSPHERE_LOG_DIR="$TEST_DIR/logs" \
bun run dev
```

The same variables work for CLI tests. Set them in the shell before running `bun run start -- <command>` so the CLI and desktop app share the same isolated config and vault:

```bash
export PHOTOSPHERE_CONFIG_DIR="$TEST_DIR/config"
export PHOTOSPHERE_VAULT_DIR="$TEST_DIR/vault"
export PHOTOSPHERE_VAULT_TYPE=plaintext
```

With an isolated config dir you start with no databases registered, so create or open one from the UI (or pre-create one with the CLI) as the test directs. This is the same isolation pattern the Electron smoke tests use (`apps/desktop/smoke-tests/lib/common.sh`).

## Structure

- [e2e/](e2e/) - End-to-end manual test scripts covering full user workflows
- [screenshots.md](screenshots.md) - Capturing desktop app screenshots via the test control server
