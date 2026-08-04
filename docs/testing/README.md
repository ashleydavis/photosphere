# Testing

Manual and automated test documentation for Photosphere.

## Running tests

All commands are run from the repo root.

Run everything (unit tests plus all smoke tests):

```bash
bun run test:all
```

Note that `test:all` covers no mobile suite, so it can pass while the mobile app is broken. For the genuine full set for your platform, all at once and in about a third of the time:

```bash
bun run test:everything
```

Or `bun run tev` for short.

Runs are gated on changed paths: a script is only run when the paths it watches (listed in `what-changed.json`) differ from what they were the last time that script passed, so a docs-only change runs nothing. Add `-- --force` to run everything regardless, or `-- --plan` to print the decision without running anything. `bun run test:everything:all` is the ungated runner.

That is also what the checked-in git hooks run. They gate commits and pushes locally, and they have to be installed once per clone. See [Git hooks](../git-hooks.md).

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

Run a single mobile smoke test by number or by name:

```bash
bun run test:and 26                     # by number
bun run test:and receive-database       # by part of the name
bun run test:and 26-receive-database    # by full directory name
```

A number matches the number in front of the directory name exactly, so `2` runs `2-create-database` and not `12-edit-api-key` or `22-edit-database-origin`. Two tests share a number today (`9` and `17`), so those two numbers each select a pair. Anything that is not all digits is a case-insensitive substring of the directory name. The same argument works on `bun run test:ios`.

Tests are selected before the emulator check and the build, so a mistyped name fails immediately and lists the available tests instead of wasting a build. `bun run test:and -- 26` also still works, if you prefer the explicit `--`.

The assertion helpers the tests call (`wait_for_value`, `assert_value`, and the rest of `common.sh`) are fatal: a helper failure ends the test immediately rather than letting it continue past a bad assumption.

### Hunting flaky tests

A suite that passes once has told you very little. A mode that fails one run in two hundred passes every normal check and still breaks a build later. `find-flakey-tests` drives the full suite in a loop and only calls it clean after a long unbroken streak of green runs:

```bash
bun run find-flakey-tests                    # until 500 consecutive green runs
bun run find-flakey-tests -- --target 100    # a shorter streak
bun run find-flakey-tests -- --resume 42     # carry on from a session that banked 42 green runs
bun run find-flakey-tests -- --help
```

It runs `bun run test:everything -- --force` each time. `--force` matters: without it the what-changed gate skips suites that have not changed, so the loop could run hundreds of times without ever exercising the suite that is flaky.

It stops at the first real failure, because the point is the streak and a streak with a failure in it is not a streak. On failure it writes a report naming the lane and the test that failed, the tail of that run's output, snapshots of the per-test log files the next run would otherwise overwrite, and the state of the machine at that moment: free memory, attached devices, and any kernel out-of-memory kills in the last hour. That last part is there because several failures found this way were caused by the machine and not the code, and none of them were visible in the suite's own output.

A crash of the Bun runtime itself (SIGSEGV, SIGILL, a panic) is not a failure of the code under test, so such a run is retried rather than counted against the streak. Five in a row stops the session, since a result resting on that many crashes would mean nothing. Every crash is listed in the summary either way, so they can never pass unnoticed.

A sick Android emulator pool is treated the same way, and only when the looped command actually drives the emulators (`test:and` and the whole set do; the unit tests, the CLI suite, the Electron suite and the iOS suite do not). The loop pauses rather than failing: it says the pool is sick, keeps the streak, and waits up to an hour for the emulators to come back, resuming by itself with however many devices are restarted. A run that went red while the pool was sick is not counted against the streak either. It gives up only if the pool stays away, or if five runs in a row go red with a sick pool.

Everything is written under `tmp/find-flakey-tests/<timestamp>/` (gitignored): one log per run, plus `report.txt` on failure. The paths are printed on the last lines of output.

Exit status is 0 when the streak is reached, 1 when a run failed, 2 on bad usage, 3 when too many Bun crashes in a row made the result meaningless, and 4 when the emulator pool it depends on did not come back.

The loop itself has no automated test. Its own behaviour on failure (counting the streak, bailing at the first failure, telling a Bun crash apart from a real failure, writing the report) is therefore unverified except by running it.

### Running the Android tests over several emulators

`bun run test:and` uses every emulator that is on the LAN bridge, one worker per device, so the suite finishes several times faster. Measured on this repo: 375s originally, 276s after the wait helpers were made to poll five times a second, and 113s across six emulators.

Bring up a pool of five alongside your own emulator:

```bash
bun run emu:and:up             # one writable emulator, keeps its state, for hand testing
bun run emu:and:pool:up        # five more, each on its own cloned AVD and its own tap
bun run emu:and:pool:down      # stops only the pool
bun run emu:and:pool:restart   # pool:down then pool:up, leaving your own emulator alone
bun run emu:and:down           # stops only your own emulator
```

Each pool emulator runs on a writable clone of your base AVD, about 8KB each, because two emulators cannot share one AVD. Set `PHOTOSPHERE_EMULATOR_COUNT` to change the pool size. Pin a run to particular devices with `PHOTOSPHERE_ANDROID_DEVICES="emulator-5556 emulator-5558"`, for example to leave your hand-testing emulator out of it.

Tests are dispatched in the order they are numbered. One marker file in a test's own directory changes scheduling, documented in [apps/smoke-tests/tests/README.md](../../apps/smoke-tests/tests/README.md): `.exclusive` serialises a test across the whole pool (the LAN-share tests need it, because discovery broadcasts on the segment every emulator shares).

With more than one worker, each test's output goes to `test-run.log` inside that test's own temporary directory (see [Every test gets its own directory](#every-test-gets-its-own-directory)) and only its status line is printed, since concurrent output would interleave. A single device keeps streaming to the terminal. The `FAIL` line and the run summary both print the full path.

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

## Every test gets its own directory

Every test, not every suite, owns a uniquely named directory for its fixtures, logs and scratch space, and gets one without asking. Tests used to share directories and interfere with each other: one suite deleted `/tmp/photosphere` while another was writing its log header there, and two concurrent mobile runs wiped each other's live bridge logs out of `tests/<name>/tmp`.

Directories live under `/tmp/photosphere-tests/` (or `$TMPDIR` where that is set), named `<test-name>-<random>`, so a stray directory always names the test that made it. That root is deliberately not the CLI's own `/tmp/photosphere`, which `psi hash-cache clear` deletes outright.

A test never asks for its directory. The runner allocates one and exports `PHOTOSPHERE_TEST_TMP_ROOT` and `TEST_TMP_DIR` pointing at it, so the test, the app it launches and every `psi` process it starts all write inside it. In a mobile or desktop test the path is in `TMP_DIR`, set by `lib/common.sh`; do not set it yourself. A test run straight from the command line, outside its runner, allocates its own the same way.

The allocator is `scripts/lib/allocate-test-temp-dir.sh`, shared by every suite: the CLI suites (plain, encrypted, LAN-share, keychain), the Electron suite and the mobile suite. Its TypeScript counterpart for unit tests is `createTestTempDir(label)` in `packages/node-utils`.

**Nothing removes these directories.** They accumulate, one per test per run. That is deliberate: keeping them is what made several intermittent failures diagnosable, and the deletion code that would clean them up is the same shape as the code that caused the `/tmp/photosphere` incident in the first place. `bun run find-flakey-tests` prints the count at the end of every session, so growth shows up on the session that caused it rather than weeks later as an unexplained slowdown. Remove them yourself when the count gets high.

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

## How a mobile smoke test sets up its state

Set state up from outside the app, before it launches. Do not add a command, an event or a seeding function to the app so a test can reach in and set state up: that is scaffolding shipped to users which serves none of them, and adding it needs the human's approval first (see the rule in `CLAUDE.md`).

The two helpers to reach for, both defined per platform in `apps/smoke-tests/lib/android.sh` and `apps/smoke-tests/lib/ios.sh`:

- `"${PLATFORM}_reset_app_state"` - wipes everything the app has stored on the device: its storage sandbox, the WebView's localStorage and the keychain. Call it before `start_app`, so the app starts from a known state and nothing can write state back underneath it. On Android this is `pm clear`; on iOS it empties the app's data container and resets the simulator keychain.
- `"${PLATFORM}_seed_databases_config" '<databases json>' '<recent names json>'` - writes the app's `databases.toml` into its storage sandbox, registering the configured databases and the recents. This is the mobile equivalent of the desktop smoke tests pre-writing `~/.config/photosphere/databases.toml`. The file is rendered on the host by `apps/smoke-tests/lib/write-databases-config.ts`, through the same `node-api` function the app writes it with, so the two cannot drift.

Alongside those, `"${PLATFORM}_seed_database"` copies a database fixture into the sandbox and `"${PLATFORM}_reset_path"` removes a path under it.

The one exception is the news feed. `POST /seed-news` still goes through the app, because the news items live in WebView localStorage and no host-side tool can write that. The other commands that stay in the app (`pick-files`, `stage-export`, `stage-pick-folder`) stand in for native interactions a test cannot drive, not for state it could write itself.

## Structure

- [e2e/](e2e/) - End-to-end manual test scripts covering full user workflows
- [screenshots.md](screenshots.md) - Capturing desktop app screenshots via the test control server
- [stories README](../../packages/user-interface/src/stories/README.md) - The stories browser and the cross-platform story player
- `apps/smoke-tests/tests/<n>-<name>/` - Mobile smoke tests (`bun run test:and` / `bun run test:ios`), platform-neutral and numbered 0-39
