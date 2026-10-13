# Photosphere smoke tests

One set of smoke tests for the Photosphere App on every platform. See [Ziggy architecture](https://github.com/ashleydavis/ziggy/blob/main/docs/architecture.md) for the test hooks the suites are allowed to use.

## Running

Run through the root `package.json` scripts, never by calling the shell scripts directly.

- `bun run test:ziggy`: the desktop suite, run on the host operating system.
- `bun run test:ziggy:and`: the suite on the Android emulator pool or a device.
- `bun run test:ziggy:ios`: the suite on the iOS simulator, or on a connected iOS device when one is plugged in (MacOS only).

Each ends with `what-changed baseline capture <name>`, and has a matching target in `what-changed.yaml` and an entry in `scripts/test-everything-parallel.sh`.

To run one scenario, name it: `PHOTOSPHERE_SMOKE_SCENARIO=<number or name> bun run test:ziggy`. See [run.md](run.md) and [run-desktop.md](run-desktop.md) for the runners.

## Scenarios

- One directory per scenario at the top of this directory, named `<n>-<name>`, with a `test.sh` inside. The runner runs them in the order of their numbers. Exit code 77 means skipped.
- Every scenario is offered to every platform. A scenario is platform-neutral and runs on desktop and mobile, with a platform check only where the behaviour differs. A scenario that cannot run on a platform exits with the skipped code itself, as the MCP server and menu scenarios do on a phone and the automatic import permission scenarios do on a desktop.
- `lib/common.sh` holds the helpers every scenario sources, and `lib/<platform>.sh` builds, starts and stops the app on one platform.
- No marker files. A runner learns what it needs to know from the test itself.

## Shared machinery

Referenced, not copied: `scripts/lib/test-pool.sh`, `test-timeout.sh`, `test-concurrency.sh`, `process-control.sh` and `test-lib.sh`. Android is driven with `adb` and iOS with `xcrun simctl`.

## Running beside other suites

Every scenario must survive running beside copies of itself and beside every other suite, including ones started from another worktree: a free port, a per-test temporary directory from `scripts/lib/allocate-test-temp-dir.sh`, every started process recorded when it is started and killed through `kill_process_tree`. `bun run test:parallel` proves it.

## Driving the app

Through the test hooks listed in the "Test hooks" section of the architecture document, and nothing else. State is otherwise set up from outside the app (config files and data placed on disk).

## Manual scenarios

`manual/` holds scenarios that measure a real device and are never part of a run of the whole suite. A run picks one up only when it is named, for example `PHOTOSPHERE_SMOKE_SCENARIO=90-perf-import bun run test:ziggy:and`. They are not run by `test:everything`.

## When the app does not become ready

`wait_for_ready` in `lib/common.sh` stops at once, with the tail of `app.log`, when a desktop app has already exited. When the app is still running but never answers, it prints the stack of every thread of the app and of each process it started before the cleanup kills them, and saves the same text as `hang-stacks.txt` in the scenario's directory. It uses `gdb` on Linux and `lldb` on macOS, says so when the tool is missing, and prints each thread's name, state and the kernel function it waits in on Linux. With the kernel's default `ptrace_scope` of 1, `gdb` is refused because the app is not a descendant of the test, and the thread table is what remains.
