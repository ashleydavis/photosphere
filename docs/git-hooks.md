# Git hooks

The local test gate. One hook refuses a commit whose tests do not pass. It is checked in, but it is **not** active until you install it once per clone.

## How git hooks work, in general

A git hook is just an executable script that git runs at a particular moment. If the script exits non-zero, git abandons the operation. There is no configuration language and no plugin system: the name of the file decides when it runs.

Three things about them are worth knowing up front, because they explain the whole setup here.

- **Hooks are not version controlled.** Git only ever runs hooks from one directory, and by default that is `.git/hooks`, which is not part of the repository. So you cannot commit a hook and have it work for everyone. A fresh clone of this repository has git's stock `*.sample` files there and nothing else, which means nothing runs at any point.
- **`core.hooksPath` is the way round that.** Setting it tells git to look somewhere else, so the scripts can live in the repository as ordinary tracked files. That setting is per clone and is not itself committed, which is why installing is a manual step and why anyone who already cloned has to run it too.
- **`--no-verify` always wins.** `git commit --no-verify` skips the hook entirely. That is git's own behaviour, not something this script implements, and it cannot be disabled. A hook is a convenience for the person running it, never a security control.

## Installing them

Once per clone:

```
bash scripts/install-hooks.sh
```

That runs `git config core.hooksPath .githooks`. Nothing runs it for you, and cloning does not.

Confirm they are active:

```
git config core.hooksPath
```

It should print `.githooks`. Anything else, including no output, means the hooks are doing nothing.

The path is set relative rather than absolute so it resolves against whichever working tree git is running in. That matters because a git worktree shares one config file with the main clone, and a relative path lets both use their own checked-in copy.

## What it runs

There is one hook, `.githooks/pre-commit`. It delegates to `bun run test:everything`, so what it runs is exactly the set you can run by hand:

| | Linux | macOS |
| --- | --- | --- |
| Compile | `bun run compile` | `bun run compile` |
| Unit tests | `bun run test` | `bun run test` |
| CLI smoke tests | `bun run test:cli` | `bun run test:cli` |
| Electron smoke tests | `bun run test:electron` | `bun run test:electron` |
| Mobile smoke tests | `bun run test:and` | `bun run test:ios` |
| Mobile native unit tests | `bun run test:and:unit` | `bun run test:ios:unit` |

The platform is detected with `uname`. The mobile toolchains do not exist on the other platform, so there is no way to run both sets from one machine.

## Why there is no pre-push

There used to be one. `pre-commit` held compile and the unit tests, and `pre-push` held the expensive suites, on the reasoning that the full set is too slow to run on every commit.

That split checked at the wrong moment. It let a broken commit exist and only complained later, at a point where the history already has the problem in it and fixing it means amending or adding a commit on top. The commit is the thing worth keeping honest, so the whole set now runs there and nothing runs at push time.

## What this costs you

The mobile suites need a device or emulator attached. With none running, **every** commit is refused, including a docs-only one, because `test:and` fails immediately with `emulator not started`.

Use `--no-verify` for those. That is a normal part of using this, not a workaround.

The upside of putting everything at commit time is that a commit which passed the hook has actually been tested, on every platform suite this machine can run. That was never true of the old `pre-commit`.

## Why everything runs in parallel

`bun run test:everything` (which runs `scripts/test-everything-parallel.sh`) starts every script at once, waits for all of them, and reports each result separately. Run one after another the same set takes around eleven minutes; started together it takes about as long as the slowest one, roughly three and a half. That difference is the difference between a hook people leave switched on and a hook people bypass.

You can run it yourself, which is the fastest way to see where you stand before pushing:

```
bun run test:everything                 # the whole set for this platform
bun run tev                             # the same thing, shorter
bun run test:everything compile test    # just those two, still in parallel
```

With no arguments it runs the whole platform set. With script names it runs exactly those. Every script's output is captured separately, and only the failures are printed at the end, each followed by the single command to re-run on its own. Working on one failure at a time beats re-running the whole set.

**It stops as soon as anything fails.** The remaining scripts are killed rather than left to finish, along with everything they started, so a failure comes back in seconds instead of after the slowest suite has run its course. There is no point waiting for an answer that is already "no", and one failure is enough to stop a commit or a push. The trade is that a run tells you about the first failure rather than all of them: anything still running is reported as cancelled with its result unknown, so a second failure elsewhere only surfaces once the first is fixed.

Two things to be aware of when running everything at once:

- `test:and` and `test:and:unit` both run `bun run sync` and Gradle against the same `apps/android-frontend/android` project, so in parallel they are two builds in one project directory. The same applies to `test:ios` and `test:ios:unit`.
- `compile` writes `dist` while the test suites read the source tree.

Neither has caused a failure in practice, but if you see a build error that makes no sense, re-run the one script on its own before believing it.

## Why the mobile suites are always included

There is no changed-paths rule and no way to opt out of the mobile suites. Every commit runs them, whatever it touches.

The old `pre-push` had a rule that made them mandatory only for changes under `packages/mobile-frontend/`, `packages/mobile-worker/`, `apps/android-frontend/`, `apps/ios-frontend/` and `apps/smoke-tests/`, and dropped them otherwise. That rule is gone with the hook it lived in. Running them every time is simpler and strictly stronger, at the cost of needing a device for every commit.

The reason they matter at all is specific. Unit tests cannot see embedded-worker task ordering or the on-device config file, and those are exactly what commit `61ac4cee` broke: it moved the mobile database list into `databases.toml` and broke 8 of 37 Android smoke tests, and it was committed and pushed without the mobile suite ever being run. `bun run test:all` would not have caught it either, because `test:all` covers no mobile suite at all.

## Checking they actually work

The hook carries no automated tests, deliberately, and `CLAUDE.md` freezes it for that reason. Testing it means faking `bun`, at which point what you have proven is the branching rather than the gate: a stub standing in for "the tests failed" is not evidence that anything would really be refused. So the only thing behind this file is that a person ran it and watched it work.

This is that procedure. Work through it once after installing, and again after any change to the hooks, which should not happen.

Everything here is safe. Nothing pushes anywhere real, and every step tells you how to undo itself.

**1. Confirm it is wired up.**

```
git config core.hooksPath
```

Must print `.githooks`. Anything else and nothing below is testing what you think.

**2. Start the device.** The mobile suites need one, and without it every commit is refused. On Linux: `bun run emu:and:pool`, then `bun run emu:and:status` until it says ready.

**3. Watch it pass.**

Make a trivial change, stage it, commit. Expect `pre-commit: running the full test set for this platform`, then the lanes, then every script reported PASS, then `pre-commit: passed`, then the commit. About three and a half minutes.

If it commits instantly with no output, the hook is not running: go back to step 1.

**4. Watch it refuse.** This is the important one.

Break the build on purpose, for example add a line reading `this is not valid typescript` to any `.ts` file, then try to commit. Expect compile to fail, the other lanes to be cancelled, `pre-commit FAILED`, and **no new commit**. Confirm with `git log`. It should come back in seconds rather than minutes, because it stops at the first failure.

A gate you have never seen refuse anything is not a gate. If this step commits, stop and fix it before trusting any of it.

**5. Watch it refuse for a failing test, not just a failing compile.**

Undo the compile breakage. Make a unit test fail instead, for example by changing an expected value in any test under `src/test/`. Commit. Expect the same refusal, this time naming `test`, with the failing test's output printed. Then undo it.

Compile failures and test failures reach the hook by different paths, so seeing only one of them prove the point is half a test.

**6. Confirm the bypass works.**

With a breakage still in place, `git commit --no-verify`. It should commit with no hook output at all. Undo the commit and the breakage afterwards.

**7. Confirm what happens with no device.**

Stop the emulators (`bun run emu:and:pool:down`) and try to commit anything, even a docs change. Expect a refusal naming `test:and`, with `emulator not started`. This is the cost of running the mobile suites on every commit, and it is worth seeing once so it is not a surprise later.

You can also run the whole thing without committing at all, which is the same set the hook runs:

```
bun run tev
```

## Bypassing

```
git commit --no-verify
```

Legitimate reasons: a docs-only commit, or a work-in-progress push to your own branch.

Not a legitimate reason: "the emulator was not running". That is the case the mobile rule exists to catch.

## Where this sits

This hook is the fast local gate. `.github/workflows/release.yml` is the slow authoritative one, and it is what decides whether a change is actually good. The hook exists to tell you in minutes what CI would have told you later.

It fixes nothing, stages nothing, and amends nothing. It reports and refuses, and leaves your working copy exactly as it was.
