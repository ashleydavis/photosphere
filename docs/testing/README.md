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

Runs are gated on changed paths: a script is only run when the paths it watches (listed in `what-changed.yaml`) differ from what they were at the last passing run, so a docs-only change runs nothing. Add `-- --force` to run everything regardless, or `-- --plan` to print the decision without running anything. `bun run test:everything:force` runs the whole set regardless. The gate needs the `what-changed` executable on your PATH, from [its releases page](https://github.com/ashleydavis/what-changed/releases).

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

Run the other CLI suites: LAN share (CLI to CLI), sync and write lock, the last two driving several processes against one database at once:

```bash
bun run test:cli:lan-share
bun run test:cli:sync
bun run test:cli:write-lock
```

Run the CLI to desktop LAN share suite, which shares secrets and databases in both directions between the CLI and the Electron app:

```bash
bun run test:lan-share:cli-desktop
```

Run the mobile test harness's own tests, covering the device run lock, the work queue and worker pool, and the timeout helper. They drive shell rather than the app, so they need no device and take seconds:

```bash
bun run test:harness
```

Run the mobile smoke tests. Each test lives at `apps/smoke-tests/tests/<n>-<name>/test.sh`, and each `test.sh` is platform-neutral: the same file runs against the Android emulator/device and the iOS simulator. List the directory to see what is there; the numbers have gaps, so the highest one is not a count:

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

A number matches the number in front of the directory name exactly, so `2` runs `2-create-database` and not `12-edit-api-key` or `22-edit-database-origin`. Where two tests share a number, that number selects both. Anything that is not all digits is a case-insensitive substring of the directory name. The same argument works on `bun run test:ios`.

Tests are selected before the emulator check and the build, so a mistyped name fails immediately and lists the available tests instead of wasting a build. `bun run test:and -- 26` also still works, if you prefer the explicit `--`.

The assertion helpers the tests call (`wait_for_value`, `assert_value`, and the rest of `common.sh`) are fatal: a helper failure ends the test immediately rather than letting it continue past a bad assumption.

### Hunting flaky tests

A suite that passes once has told you very little. A mode that fails one run in two hundred passes every normal check and still breaks a build later. `find-flakey-tests` drives the full suite in a loop and only calls it clean after a long unbroken streak of green runs:

```bash
bun run find-flakey-tests                    # asks what to loop, then how long a streak
bun run find-flakey-tests -- --script test   # loop one suite: test, test:cli, test:electron, test:and, test:ios
bun run find-flakey-tests -- --target 500    # a longer streak
bun run find-flakey-tests -- --resume 42     # carry on from a session that banked 42 green runs
bun run find-flakey-tests -- --ladder        # each suite in turn, cheapest first
bun run find-flakey-tests -- --help
```

**Run with no arguments on a terminal and it asks** rather than assuming: which suite to loop (the five above plus `everything` and `ladder`), then, for a single suite, whether to narrow to one test by number or part of its name, then how many consecutive green runs to require. Every prompt has a default, so pressing enter three times gives you `everything` until 100 green runs, which is what it used to do without asking. Passing `--script`, `--command` or `--ladder` skips the questions, and so does a run with no terminal attached, which is why the git hook and CI never block on it.

`--ladder` climbs the suites one at a time instead of looping the whole set: the full streak of the cheapest suite, then the next, on up through every suite the pre-commit hook runs, stopping at the first rung that fails. Looping everything is the slowest possible way to find a flaky unit test, and a red unit run names its test in seconds where the same failure inside a parallel run of everything has to be dug out of a lane. Each rung's run logs go in their own numbered subdirectory of the session, and a failure prints the command to carry on from that rung once it is fixed, since the rungs below it are already proven on this tree. `--target` is the streak required of every rung, and `--resume` applies to the first rung only, the one the session restarts on. Name your own rungs (from the same suites `--script` accepts) to climb something else: `--ladder "test test:cli test:ios"` is how to include the iOS suite on macOS, which the default rungs leave out because it can never pass on Linux.

Before each run it prints when that run should end and when the whole streak should, as a clock time and as a time from now. The estimate is the mean of the last ten runs, so it appears from the second run onwards, tightens as the session goes on, and follows the machine as it speeds up or slows down instead of staying anchored to how the session began. It counts time spent running only, so a pause waiting for an emulator pool, or a crashed run that is retried, puts the real finish later than the estimate says.

It runs `bun run test:everything -- --force` each time. `--force` matters: without it the gate skips suites that have not changed, so the loop could run hundreds of times without ever exercising the suite that is flaky.

It stops at the first real failure, because the point is the streak and a streak with a failure in it is not a streak. On failure it writes a report naming the lane and the test that failed, the tail of that run's output, snapshots of the per-test log files the next run would otherwise overwrite, and the state of the machine at that moment: free memory, attached devices, and any kernel out-of-memory kills in the last hour. That last part is there because several failures found this way were caused by the machine and not the code, and none of them were visible in the suite's own output.

A crash of the Bun runtime itself (SIGSEGV, SIGILL, a panic) is not a failure of the code under test, so such a run is retried rather than counted against the streak. Five in a row stops the session, since a result resting on that many crashes would mean nothing. Every crash is listed in the summary either way, so they can never pass unnoticed.

A sick Android emulator pool is treated the same way, and only when the looped command actually drives the emulators (`test:and` and the whole set do; the unit tests, the CLI suite, the Electron suite and the iOS suite do not). The loop pauses rather than failing: it says the pool is sick, keeps the streak, and waits up to an hour for the emulators to come back, resuming by itself with however many devices are restarted. A run that went red while the pool was sick is not counted against the streak either. It gives up only if the pool stays away, or if five runs in a row go red with a sick pool.

Everything is written under `tmp/find-flakey-tests/<timestamp>/` (gitignored): one log per run, plus `report.txt` on failure. The paths are printed on the last lines of output.

Exit status is 0 when the streak is reached, 1 when a run failed, 2 on bad usage, 3 when too many Bun crashes in a row made the result meaningless, and 4 when the emulator pool it depends on did not come back.

The loop itself has no automated test. Its own behaviour on failure (counting the streak, bailing at the first failure, telling a Bun crash apart from a real failure, writing the report) is therefore unverified except by running it.

Once a suite is sound on its own, the next question is whether it is sound in company. That is [Hunting suites that break each other](#hunting-suites-that-break-each-other), below.

### Hunting suites that break each other

`bun run test:everything` starts the suites concurrently, so two of them that touch the same file, port, directory, lock or device can fail each other in ways that never show up when either is run alone. That is a different failure class from ordinary flakiness: the suite is not unreliable in itself, it is unreliable in company. It is also on the commit path, because that parallel runner is what the git hooks run, so a pair that interferes refuses a commit with a failure nobody can reproduce afterwards.

`check-parallel-tests` runs every selected script alone first, then runs every combination of two of them at the same time, and reports only the failures that appear in company and not alone:

```bash
bun run test:parallel                              # everything this machine can run, mobile included
bun run test:parallel -- --scripts "test test:cli" # just these two, for a quick answer
bun run test:parallel -- --help
```

**A default run needs the emulator pool already up.** It checks every suite `bun run test:everything` starts in a parallel lane, plus the mobile suites this machine can actually run: each script alone, then every pair of them. Those are the suites that already run beside each other on every commit, so a pair that contends refuses a commit whether or not this check looked at it. `compile` is left out (a build, not a suite), and so are the native unit suites, which `test:everything` already keeps apart from their own smoke suites. The number of pairs grows with the square of the number of suites, so name `--scripts` explicitly when you want a quick answer: that gives you precisely the scripts you asked for and no mobile detection.

**Everything runs once.** Each script alone once, each combination once. A conflict that only shows up on some runs will be missed, so this answers whether a conflict is there, not how often it happens. That is a deliberate trade for a run you might actually start: `bun run find-flakey-tests` is the tool for the second question.

`test:ios` is included only on macOS, and `test:and` only where the Android tooling is installed and `bun run emu:and:status` reports a ready device. Either one that cannot run is dropped with a printed reason rather than left in to fail every combination it appears in, and the summary says how many combinations went unchecked as a result, so a reduced run can never be mistaken for a clean one. The check never starts, stops or restarts an emulator: that is the human's job.

**Self-pairs are included**, so three scripts is 6 combinations rather than 3: each script is also checked against a second copy of itself. Nothing in `test:everything` runs one suite twice at once, but two worktrees, two developers on one machine, or a rerun started before the last one finished all do. A self-pair failure means exactly that: the suite cannot be run twice at once, usually because it hardcodes a path, a port or a lock.

**Nothing is muted.** The pairs `SERIAL_GROUPS` in `scripts/test-everything-parallel.sh` already keeps apart (`test:and:unit` with `test:and`, `test:ios:unit` with `test:ios`) are reported as interference like any other, because a known conflict is still a conflict. They are also the positive control: run `bun run test:parallel -- --scripts "test:and test:and:unit"` and a check that does not report them is a check that is not working.

The three verdicts:

- **ok** - both scripts are sound alone and both sides passed when run together.
- **interference** - both scripts are sound alone and at least one side failed when they ran together. This is a real finding: record it in the "Parallel-only failure modes" section of [the flaky-test registry](../flaky-tests-registry.md), naming the pair and the shared resource.
- **inconclusive** - at least one script failed on its own, so nothing the pair did proves anything. Ordinary flakiness has masked the answer. Run `bun run find-flakey-tests -- --script <name>` on that script first: the two tools are a pair, one proves a suite is sound alone and the other proves it is sound in company, and the second is only meaningful once the first has passed.

Exit status is 0 when nothing was found, 1 when interference was, 2 on bad usage, 3 when too many Bun crashes in a row made the result meaningless, 4 when the emulator pool degraded mid-run, and 5 when nothing was found but something was inconclusive.

Everything is written under `tmp/parallel-check/<timestamp>/` (gitignored): one log per side, plus a `report.txt` on a finding that names the failing side, quotes the useful part of the log, and records the state of the machine. Nothing is ever deleted or overwritten, so old sessions are yours to clear.

The check itself has no automated test. Like `find-flakey-tests`, it is an instrument rather than something on the commit path, and its own behaviour is verified by running it.

### Running both, and fixing what they find

`/test:harden` is the slash command that drives the pair in the order that costs least: it asks how many green runs a rung the ladder should require, runs `bun run test:parallel` first because it is the cheaper of the two, then `bun run find-flakey-tests -- --ladder --target <target>`, and fixes what either turns red, one minimal committed fix at a time in a worktree, until both pass.

Ten runs a rung is the usual answer to its question. Below about ten the result says very little, since a mode that fails one run in fifty passes a short streak most of the time. Name a few rungs with `--ladder "..."` to climb part of the set rather than all of it. The parallel check has no equivalent number: it runs each combination exactly once whatever is chosen.

The command is at `.claude/commands/test/harden.md`, and everything it does can be done by hand with the two commands above.

### Running the Android tests over several emulators

`bun run test:and` uses every emulator that is on the LAN bridge, one worker per device, so the suite finishes several times faster. Measured on this repo: 375s originally, 276s after the wait helpers were made to poll five times a second, and 113s across six emulators.

Measured again on five emulators with 43 tests, standalone with a warm build and nothing else running: **161s before, 135-138s after**. It came down from four places, none of which deleted a test, skipped one or loosened an assertion:

- One test waited out a fixed minute for an outcome the app had already ruled out (`43-s3-failure`, 73s to 11s).
- The kill helpers poll for the process being gone instead of sleeping a fixed second per test.
- The APK checksum is hashed once per run rather than once before each of the 43 tests.
- The LAN-share tests are no longer serialised against each other, which was 102s that could not overlap inside a 145s loop.

See `docs/plans/done/plan-halve-test-and-duration.md` for every measurement.

Take any measurement only when the machine is quiet. The same suite measured 231s while another `bun run test:everything` was running beside it, because `suite_share` hands a competing suite a fraction of the emulators.

Bring up a pool of five alongside your own emulator:

```bash
bun run emu:and:up             # one writable emulator, keeps its state, for hand testing
bun run emu:and:pool:up        # five more, each on its own cloned AVD and its own tap
bun run emu:and:pool:down      # stops only the pool
bun run emu:and:pool:restart   # pool:down then pool:up, leaving your own emulator alone
bun run emu:and:down           # stops only your own emulator
```

Each pool emulator runs on a writable clone of your base AVD, about 8KB each, because two emulators cannot share one AVD. Set `PHOTOSPHERE_EMULATOR_COUNT` to change the pool size. Pin a run to particular devices with `PHOTOSPHERE_ANDROID_DEVICES="emulator-5556 emulator-5558"`, for example to leave your hand-testing emulator out of it.

### The mobile tests wipe the app's data, and will not do it to a real phone

Every mobile test starts by clearing the app's stored data, because a test that ran on state an earlier one left behind would pass or fail for reasons that have nothing to do with it. That wipe takes the storage sandbox with it: every database the app holds and everything imported into them.

On an emulator that costs nothing, since a pool emulator holds only what a test put there. On a real phone it is somebody's photo library, and importing one takes the best part of an hour, so **the harness refuses to wipe a real device**. A run that needs the wipe and cannot have it fails and says so rather than testing against whatever was already there.

Set `PHOTOSPHERE_ALLOW_DEVICE_WIPE=1` to say the phone's data is yours to destroy:

```bash
PHOTOSPHERE_ALLOW_DEVICE_WIPE=1 PHOTOSPHERE_ANDROID_DEVICES="<serial>" bun run test:and
```

That is what the import performance test needs, since it measures an import starting from an empty database. Without the flag, a mobile test run against a real phone stops at the first test that wants a clean app.

Anything reached by `adb connect` counts as a real device and is protected the same way. Only a local `emulator-<port>` target is wiped without asking.

`bun run and` never wipes anything: it installs over the top and leaves the app's data alone, so it is the way to put a new build on a phone whose database you want to keep. Passing a fixture (`bun run and 50`, `and1`, `and0`) does replace that one fixture database, and nothing else.

Tests are dispatched in the order they are numbered, and nothing reorders or serialises them: there are no scheduling markers, so any test may run beside any other. The LAN-share tests are safe in company because discovery is disambiguated by the pairing code rather than by scheduling. See [apps/smoke-tests/tests/README.md](../../apps/smoke-tests/tests/README.md).

Every run ends with a timing block: where the wall clock went (build, install, loop, total), how many seconds of test work were done across how many workers, the packing efficiency (test work as a share of the emulators' available time, so a low number means they sat idle rather than that the tests are slow), and the ten slowest tests. That block is how to tell whether a change made the suite faster, and it is where to look for the test that is setting the length of a run.

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

The web build has no scripted runner: start it with `bun run dev:web`, open `http://localhost:8080/#/stories`, and click **▶ Play on automatic** to cycle the stories by hand. The port is `apps/dev-frontend/vite.config.ts`, which pins 8080.

Screenshots go to `stories-screenshots/<platform>/`, with an `index.html` showing each story's light and dark shots side by side. Add `-- --open` to open it when the run finishes.

Running the stories on Android or iOS renders every page at phone resolution, which is the quickest way to catch a page that does not fit on mobile (content pushed off-screen, buttons out of reach, text clipped).

These runs are long, so they are excluded from `bun run test:all`.

See [the stories README](../../packages/user-interface/src/stories/README.md) for the full reference: entry points on each platform, all runner options, how the cycle works, and how to add a new story.

## No test may touch the terminal

Every command a test runs must be given its non-interactive flag: `--yes` for `psi`, `-nostdin` for `ffmpeg`. A test has no user at a keyboard, and a command that reaches for the terminal anyway does not merely misbehave, it stops dead.

The reason is process groups. Each CLI smoke test runs under `timeout`, which puts the test in a process group of its own, and that group is not the terminal's foreground group. Reading the terminal from there, or switching it into raw mode, makes the kernel stop the process, and nothing ever resumes it. The test then sits there producing no output until the suite's 300 second timeout kills it.

This only happens when a terminal is attached, so the git hook, CI and any piped run never see it and the same tests pass there. That asymmetry is what made it look like flakiness: four tests (`74-s3-failures` and `77-s3-large-file` calling `ffmpeg`, `78-dbs-share-cancel` and `79-secrets-share-cancel` running a spinning `psi dbs send`) timed out together on an interactive run and passed on every unattended one.

On the `psi` side `--yes` now carries this meaning. `spinner(interactive)` in `apps/cli/src/lib/spinner.ts` hands back the animated spinner when someone is watching and plain log lines when nobody is, so a non-interactive run says the same things without the terminal ever being taken hold of. A command run without `--yes` behaves exactly as it always did.

## Every test gets its own directory

Every test, not every suite, owns a uniquely named directory for its fixtures, logs and scratch space, and gets one without asking. Tests used to share directories and interfere with each other: one suite deleted `/tmp/photosphere` while another was writing its log header there, and two concurrent mobile runs wiped each other's live bridge logs out of `tests/<name>/tmp`.

Directories live under `/tmp/photosphere-tests/` (or `$TMPDIR` where that is set), named `<test-name>-<random>`, so a stray directory always names the test that made it. That root is deliberately not the CLI's own `/tmp/photosphere`, so no test can reach into what a real `psi` run is using.

A test never asks for its directory. The runner allocates one and exports two variables pointing at it, so the test, the app it launches and every `psi` process it starts all write inside it. In a mobile or desktop test the path is in `TMP_DIR`, set by `lib/common.sh`; do not set it yourself. A test run straight from the command line, outside its runner, allocates its own the same way.

- `TEST_TMP_DIR` is the test harness's own variable, naming the directory this test keeps its fixtures, vault, config and scratch space in. The shell suites read it; nothing in the application does.
- `PHOTOSPHERE_TMP_DIR` is an application setting, not a test one: it tells Photosphere where to put its temporary files, and any user can set it (it is listed on the wiki's Environment Variables page alongside `PHOTOSPHERE_LOG_DIR` and the rest). The runner points it at the test's directory so the app's own scratch files land there too. Without it every `psi` process on the machine shares one location, which is how `psi hash-cache clear` once deleted a directory out from under a suite running alongside (it cleared the whole of `/tmp/photosphere` back when one hash cache served the machine; it now clears one database's cache directory).

The allocator is `scripts/lib/allocate-test-temp-dir.sh`, shared by every suite: the CLI suites (plain, encrypted, LAN-share, keychain), the Electron suite and the mobile suite. Its TypeScript counterpart for unit tests is `createTestTempDir(label)` in `packages/node-utils`.

**Nothing removes these directories.** They accumulate, one per test per run. That is deliberate: keeping them is what made several intermittent failures diagnosable, and the deletion code that would clean them up is the same shape as the code that caused the `/tmp/photosphere` incident in the first place. `bun run find-flakey-tests` prints the count at the end of every session, so growth shows up on the session that caused it rather than weeks later as an unexplained slowdown. Remove them yourself when the count gets high.

## Every suite cleans up its processes, and proves it

A suite starts real processes: an Electron app under `xvfb-run`, an X server, a control bridge, a `psi` process per CLI test. Every one of those is stopped by the suite that started it, and every suite checks at the end that it left none of them running.

Stopping is by process group, not by walking the process tree. A tree walk asks the kernel who a process's children are, so it only works while the parent is alive: the moment the parent dies its children are reparented to init and the walk finds nothing, which is exactly the state a leak leaves behind. A process group survives reparenting, so `kill -- -<pgid>` still reaches every member. `scripts/lib/process-control.sh` is the one implementation of this, shared by the desktop suite, the mobile suite, both CLI suites and the story player.

The group is made with bash job control, not with `setsid`. Monitor mode is turned on for the launch alone and put back as it was found, and while it is on the shell puts each background job in a new process group whose pgid is the job's own pid. That works on Linux and macOS alike, where `setsid` is util-linux and does not exist at all. There is no branch on the host anywhere in the library, so there is no platform that silently gets a reduced version of the cleanup.

That job control really does this is checked at runtime rather than trusted, once per shell, by `process_control_verify_job_control`. It starts a real background job and asks the kernel which group the job landed in. If the answer is not a group of the job's own, launching refuses outright and says so, instead of handing back a process group id that was never confirmed. The distinction matters more than it looks: a missed process group leaks, but a wrong one names some other process's group, and the cleanup then kills whatever is inside it.

The leak check runs at the end of `apps/desktop/smoke-tests.sh` and `apps/smoke-tests/run.sh`. Each app or control bridge a test launches records its process group in the file named by `PHOTOSPHERE_LAUNCHED_GROUPS`, which the runner exports before it starts anything; at the end the runner reports whatever is still alive in those groups and fails the run. **A leak check failure on a run whose tests all passed is a real failure, not noise.** It means the suite left something on the machine, and enough of those is what took the machine into an out-of-memory kill that took the Android emulator pool with it. Fix the cleanup that missed; do not delete the check.

It is scoped to the groups the suite itself created, and that precision is load-bearing rather than tidiness. `bun run test:everything` runs a dozen suites at once in one checkout, so anything looser (matching this checkout's path, say) makes every suite report the others' live processes as its own leak. Naming the groups also reaches processes that match no pattern at all: the `Xvfb` server and Electron's utility processes are in the group but mention this checkout nowhere.

The CLI suite has no leak check. Nothing in it launches through `launch_in_process_group` (a test starts `psi` directly inside its batch subshell), so there is no group to scope to, and a check there could never fire. What keeps that suite from leaking is that its interrupt and exit traps kill each batch subshell's whole process tree rather than just the subshell.

There is one case the cleanup cannot cover, and nothing else covers it either. A SIGKILL runs no handler, so when `systemd-oomd` decides the machine is out of memory, or a runner is hard-killed, whatever was running is left behind however careful the suite was. The leak check will report those processes on the next run that notices them, but stopping them is a manual job: find them with `ps -A -o pid,ppid,args | grep <path to this checkout>` and kill what is orphaned (`-A` rather than `-e`, because macOS reads `-e` as "show the environment too").

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
- `apps/smoke-tests/tests/<n>-<name>/` - Mobile smoke tests (`bun run test:and` / `bun run test:ios`), platform-neutral and numbered
