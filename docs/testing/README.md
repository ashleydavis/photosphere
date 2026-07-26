# Testing

Manual and automated test documentation for Photosphere.

## Running tests

All commands are run from the repo root.

Run everything (unit tests plus all smoke tests):

```bash
bun run test:all
```

Run all unit tests:

```bash
bun run test
```

Run a single unit test by name or pattern:

```bash
bun run test -- <test-name-or-pattern>
```

Run unit tests in watch mode:

```bash
bun run test:watch
```

Run the Electron smoke tests. This builds the Electron app and runs the smoke tests against it:

```bash
bun run test:electron
```

Run all CLI smoke tests:

```bash
bun run test:cli
```

Run a single CLI smoke test by number or name:

```bash
bun run test:cli -- 43
bun run test:cli -- replicate-partial
```

Run the encrypted CLI smoke tests:

```bash
bun run test:cli:encrypted
```

Run the hash cache concurrency smoke test, which proves that parallel processes can share one hash cache without losing entries:

```bash
bun run test:cli:hash-cache
```

Run the mobile smoke tests. Each test lives at `apps/smoke-tests/tests/<n>-<name>/test.sh`, numbered 0-39, and each `test.sh` is platform-neutral: the same file runs against the Android emulator/device and the iOS simulator:

```bash
bun run test:and   # Android emulator or attached device
bun run test:ios   # iOS simulator (needs macOS with Xcode)
```

Run a single mobile smoke test by number:

```bash
bun run test:and -- 26
```

The assertion helpers the tests call (`wait_for_value`, `assert_value`, and the rest of `common.sh`) are fatal: a helper failure ends the test immediately rather than letting it continue past a bad assumption.

Run every test across the monorepo via the shell script, which prints a summary of results. It does not run the tests in parallel, which makes it easier to see where a failure originates:

```bash
./run-tests.sh
```

Run performance benchmarks:

```bash
bun run perf
```

Capture desktop app screenshots headlessly (for UX review / docs):

```bash
bun run screenshots
```

## UI stories

The stories browser mounts every page, modal, dialog, and component in isolation with mock data, so each UI surface can be checked without seeding a real database. It is the main tool for reviewing how the UI looks, including how it fits on a small screen.

The story player cycles the live app through every story (in light and then dark), captures a screenshot of each, and fails if any story crashes while rendering:

```bash
bun run stories            # Electron desktop
bun run stories:and    # Android emulator or attached device
bun run stories:ios        # iOS simulator
```

The web build has no scripted runner: start it with `bun run dev:web`, open `http://localhost:3000/#/stories`, and click **▶ Play on automatic** to cycle the stories by hand.

Screenshots go to `stories-screenshots/<platform>/`, with an `index.html` showing each story's light and dark shots side by side. Add `-- --open` to open it when the run finishes.

Running the stories on Android or iOS renders every page at phone resolution, which is the quickest way to catch a page that does not fit on mobile (content pushed off-screen, buttons out of reach, text clipped).

These runs are long, so they are excluded from `bun run test:all`.

See [the stories README](../../packages/user-interface/src/stories/README.md) for the full reference: entry points on each platform, all runner options, how the cycle works, and how to add a new story.

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

The same variables work for CLI tests. Set them in the shell before running `bun run start -- <command>` so the CLI and desktop app share the same isolated config and vault. If you are in a fresh shell (or did not run the desktop block above), set `TEST_DIR` first to the same path:

```bash
TEST_DIR="/tmp/photosphere-isolated-$$"
mkdir -p "$TEST_DIR"/{config,vault,logs}

export PHOTOSPHERE_CONFIG_DIR="$TEST_DIR/config"
export PHOTOSPHERE_VAULT_DIR="$TEST_DIR/vault"
export PHOTOSPHERE_VAULT_TYPE=plaintext
```

With an isolated config dir you start with no databases registered, so create or open one from the UI (or pre-create one with the CLI) as the test directs. This is the same isolation pattern the Electron smoke tests use (`apps/desktop/smoke-tests/lib/common.sh`).

## Structure

- [e2e/](e2e/) - End-to-end manual test scripts covering full user workflows
- [screenshots.md](screenshots.md) - Capturing desktop app screenshots via the test control server
- [stories README](../../packages/user-interface/src/stories/README.md) - The stories browser and the cross-platform story player
- `apps/smoke-tests/tests/<n>-<name>/` - Mobile smoke tests (`bun run test:and` / `bun run test:ios`), platform-neutral and numbered 0-39
