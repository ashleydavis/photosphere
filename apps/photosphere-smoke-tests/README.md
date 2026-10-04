# Ziggy smoke tests

One set of smoke tests for Ziggy on every platform. See [Ziggy architecture](../../packages/ziggy/docs/architecture.md) for the test hooks the suites are allowed to use.

## Running

Run through the root `package.json` scripts, never by calling the shell scripts directly.

- `bun run test:ziggy`: the desktop suite, run on the host operating system.
- `bun run test:ziggy:and`: the suite on the Android emulator pool or a device.
- `bun run test:ziggy:ios`: the suite on the iOS simulator (MacOS only).

Each ends with `what-changed baseline capture <name>`, and has a matching target in `what-changed.yaml` and an entry in `scripts/test-everything-parallel.sh`.
## Scenarios

- One directory per scenario, named `<n>-<name>`, with a `test.sh` inside. Exit code 77 means skipped.
- A scenario is platform-neutral and runs on desktop and mobile, with a platform check only where the behaviour differs. A scenario that only makes sense on one platform (a mobile background import test, the desktop developer screen test) is restricted to it.
- No marker files. A runner learns what it needs to know from the test itself.

## Shared machinery

Referenced, not copied: `scripts/lib/test-pool.sh`, `test-timeout.sh`, `test-concurrency.sh`, `process-control.sh` and `test-lib.sh`. Android is driven with `adb` and iOS with `xcrun simctl`.

## Running beside other suites

Every scenario must survive running beside copies of itself and beside every other suite, including ones started from another worktree: a free port, a per-test temporary directory from `scripts/lib/allocate-test-temp-dir.sh`, every started process recorded when it is started and killed through `kill_process_tree`. `bun run test:parallel` proves it.

## Driving the app

Through the test hooks listed in the "Test hooks" section of the architecture document, and nothing else. State is otherwise set up from outside the app (config files and data placed on disk).
