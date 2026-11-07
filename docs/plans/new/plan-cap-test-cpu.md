# Cap test runs at a share of the machine's CPU

## Overview

Several worktrees run `bun run tev` at the same time, and nothing bounds what they take between them. A reading taken while eleven worktrees were running showed a load average of 110 on a 24 core machine, 0.2% idle, and 43GB of swap in use against 43GB of resident memory. The emulator pool is already bounded for memory by `psphere-pool.slice`, but nothing anywhere bounds CPU: `systemctl --user show psphere-pool.slice -p CPUQuotaPerSecUSec` reports `infinity`.

This plan puts a CPU ceiling on Photosphere's work as a whole, so that concurrent test runs share one budget instead of each taking whatever they can get. The mechanism is the one the repository already uses for emulator memory: a checked-in systemd slice unit installed into the user's unit directory, with processes started inside it.

The design rests on a property of systemd slice naming that was confirmed on this machine: a slice's parent is derived from the dashes in its name, so `psphere-pool.slice` is already a child of `psphere.slice`, and its live control group path is `/user.slice/user-1000.slice/user@1000.service/psphere.slice/psphere-pool.slice`. A `CPUQuota` written on a new `psphere.slice` therefore bounds the emulator pool and the test runs together, with no change to `emulator.sh` and no change to how emulators are started.

## Issues

## Steps

1. **Write the documentation first, then STOP.**

    Create `docs/testing/cpu-limits.md` covering: what the cap is and why it exists (the measured overload described in the Overview); the slice hierarchy (`psphere.slice` as the parent carrying the CPU quota, `psphere-pool.slice` for emulators and `psphere-tests.slice` for test runs as its children); how the absolute quota is derived from the machine's core count rather than written down; how a run opts out; how to see the cap in effect (`systemctl --user show psphere.slice -p CPUQuotaPerSecUSec`, the slice's `cpu.max`, and `systemd-cgtop`); and that the whole mechanism is Linux and systemd only, so macOS runs are unaffected.

    Create `scripts/lib/test-slice.md` beside the script added in step 3, per the repository rule that every new script comes with a markdown file naming what it is for, how it is invoked and what each argument means. Link to `docs/testing/cpu-limits.md` for the full reasoning rather than repeating it.

    Add a section to `docs/testing/README.md` under "Running tests" pointing at `docs/testing/cpu-limits.md`, saying in a sentence or two that concurrent runs share one CPU budget and naming the opt-out.

    Add a bullet to the "Guides" list in `CLAUDE.md` for `docs/testing/cpu-limits.md`.

    STOP here. Do not continue to step 2. Wait for the human to read the documentation and approve it. If the human revises it, revise steps 2 through 8 to match before implementing anything.

2. **Add the parent slice unit.**

    Create `scripts/psphere.slice`, modelled on `apps/android-frontend/scripts/psphere-pool.slice`: a `[Unit]` section with a `Description`, a comment block explaining what a slice is, that this one is the parent of `psphere-pool.slice` and `psphere-tests.slice` by name derivation, why the cap exists, and how to check it is in effect.

    The file must not carry a `CPUQuota` line. `CPUQuota` is absolute (100% means one core), so any number written here is right on one machine and wrong on the next. The comment block must say that, and say that the quota arrives as a generated drop-in installed beside the unit, derived from the share constant in `scripts/lib/test-slice.sh`.

    No code runs in this step, so there is nothing to compile or test. It is complete when the file exists and reads correctly.

3. **Add `scripts/lib/test-slice.sh`.**

    A new shell library, sourced by the runners, exposing these functions. Every function gets a `#` comment block above it, per the repository's comment rules.

    - `TEST_CPU_SHARE_PERCENT`: a constant holding the share of the machine Photosphere's work may take, set to `80`. This is the single source of truth for the number. The comment above it must say the absolute quota is this multiplied by the core count, and must not restate the resulting figure, which changes with the machine.

    - `test_slice_supported`: returns success only when this machine can enforce the cap. It must check that the platform is Linux, that `systemd-run` and `systemctl` are on PATH, that a user manager is reachable, and that the `cpu` controller is delegated to the user's slice (readable from `cgroup.controllers` under the user manager's control group). Returns failure quietly on macOS, where none of this exists.

    - `ensure_test_slices`: installs `scripts/psphere.slice` and `scripts/psphere-tests.slice` into `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user`, generates the computed quota drop-in at `psphere.slice.d/50-cpu-quota.conf` under the same directory, and runs `systemctl --user daemon-reload` when anything changed. Follow `ensure_pool_slice` in `apps/android-frontend/scripts/emulator.sh` exactly for the drift handling: the repository copy is the source of truth, an installed copy that differs is replaced rather than left alone, and what it had and what it gets are printed first so an intentional local change is visible rather than silently lost. Generate the drop-in to a temporary file under the repository's `tmp/` and compare it with `cmp -s` so an unchanged machine does not reload the user manager on every run.

    - `test_slice_cpu_quota_percent`: prints the absolute quota, the core count from `nproc` multiplied by `TEST_CPU_SHARE_PERCENT`. Called only after `test_slice_supported` has passed, so `nproc` is never reached on macOS.

    - `assert_test_slice_enforced`: reads `cpu.max` back from the live control group of `psphere.slice` and fails loudly, naming the slice and what it read, when the value is `max` or does not match the quota that was just installed. This exists because a quota that silently fails to apply leaves the machine looking bounded while it is not, which is the failure mode the pool slice's own comments describe for memory.

    - `reexec_in_test_slice`: re-executes the calling script inside a transient scope in `psphere-tests.slice`, using `systemd-run --user --quiet --scope --slice=psphere-tests.slice`. It must return without doing anything when `test_slice_supported` fails, when `PHOTOSPHERE_NO_CPU_LIMIT` is set to a non-empty value, or when the guard environment variable it sets is already present, so the re-exec happens once and never loops. Let systemd name the scope itself rather than passing `--unit`, so two worktrees starting a run at the same moment cannot collide on a unit name. When it skips because of `PHOTOSPHERE_NO_CPU_LIMIT`, it must print one line saying the run is uncapped, so an uncapped run is never silent.

    Confirmed on this machine and relied on by this step: `systemd-run --user --quiet --scope` propagates the child's exit status (checked with an exit of 42), passes stdout and stderr through unchanged, and prints no unit banner under `--quiet`. A `CPUQuota` of 1920% set on a slice was read back from that slice's `cpu.max` as `1920000 100000`.

    Per the repository rule, do not write a `*.test.sh` for this file. It is complete when `bash -n scripts/lib/test-slice.sh` parses cleanly and step 7's checks pass.

4. **Add the tests slice unit.**

    Create `scripts/psphere-tests.slice`. It carries no `CPUQuota` of its own: the ceiling belongs to the parent, and a quota here would cap a lone test run to a share of a share even when the emulators are idle. Give it a `CPUWeight` so that under contention the test runs and the emulator pool divide the parent's budget on a stated ratio rather than an accidental one, and state the chosen ratio and the reason in the file's comment block.

    Setting `CPUWeight` on the tests slice alone decides nothing, because weight is relative between siblings. Either also add a matching `CPUWeight` to `apps/android-frontend/scripts/psphere-pool.slice`, or state in both files that the pool keeps the default weight and what that makes the effective split. Do not leave the ratio implied.

5. **Wire the runner up.**

    In `scripts/test-everything-parallel.sh`, source `scripts/lib/test-slice.sh` and call `ensure_test_slices`, `assert_test_slice_enforced` and `reexec_in_test_slice` immediately after the `cd "$REPO_DIR"` near the top, before any argument parsing or lane building, so the re-executed copy does the real work exactly once.

    Check while implementing that the re-exec does not disturb the argument handling: the script is re-executed with `"$@"`, and the `--` separator that `bun run test:everything -- --force` produces must survive it.

    The lane machinery is unaffected by design. `kill_tree` walks `pgrep -P` from each lane's pid, and a scope changes the control group of the processes without changing their parent and child relationships, so the existing kill path still reaches everything. Confirm this holds during step 7 rather than assuming it.

6. **Wire up the interference checker.**

    Do the same in `scripts/check-parallel-tests.sh`. It starts suites directly rather than through `test-everything-parallel.sh`, so without this it runs uncapped, and it is the script that deliberately runs suites two at a time.

    Consider whether `scripts/find-flakey-tests.sh` needs anything: it loops `bun run test:everything -- --force`, so each iteration is capped by step 5 already and it should need no change. Read it and confirm that rather than assuming it.

7. **Verify the cap on a real run, and measure what it costs.**

    Start a run with `bun run tev` and, while it is running, record: `systemctl --user show psphere.slice -p CPUQuotaPerSecUSec`, the `cpu.max` and `cpu.stat` of the `psphere.slice` control group, and `systemd-cgtop` output showing the slice's actual usage. `cpu.stat` reports `nr_throttled` and `throttled_usec`, which is the direct evidence that the quota is being enforced rather than merely configured.

    Then run the same set with `PHOTOSPHERE_NO_CPU_LIMIT=1` and compare wall clock times, so the cost of the cap is a measured number rather than a guess.

    Quota is enforced in 100ms periods, so a heavily parallel run is throttled in bursts, and this repository's suites carry timeouts. Watch specifically for suites failing on timeout under the cap that pass without it. If that happens, that is the signal to lower the share, or to drop the parent quota and rely on `CPUWeight` alone, which only bites under contention and cannot cause throttling on an otherwise idle machine. Record whichever was chosen and why in `docs/testing/cpu-limits.md`.

    Confirm the failure path still works: make a suite fail under the cap and check that the other lanes are killed and the run reports properly, which exercises the `kill_tree` path from step 5 through the scope.

8. **Update the documentation to match the final code.**

    Revise `docs/testing/cpu-limits.md`, `scripts/lib/test-slice.md` and the `docs/testing/README.md` section so they describe what was built, including the share actually chosen, the `CPUWeight` ratio from step 4, and the measurements from step 7. If step 7 led to `CPUWeight` alone rather than a parent quota, rewrite the mechanism description rather than patching around it.

## Unit Tests

None. Everything this plan adds is shell, and the repository rule is explicit that shell scripts get no tests and that no `*.test.sh` files are to be created. The thing that proves this harness change works is running the real suites under it, which is step 7 and the Verify section below.

If any part of this ends up in TypeScript rather than shell, that part needs unit tests per the normal rule, and the plan should be revised to name them before that code is written.

## Smoke Tests

The existing suites are the smoke test for this change: the whole point is that they still pass, and still fail correctly, while running inside the cap. No new smoke test script is added.

- `bun run tev -- --force` completes and passes with the cap in place.
- The same set passes with `PHOTOSPHERE_NO_CPU_LIMIT=1`, showing the opt-out path is not broken.
- `bun run test:parallel` still reports what it reported before the change, so the interference checker is not itself broken by running inside a scope.
- A deliberately failing suite still kills the remaining lanes and reports the failure with its output, run under the cap.

## Verify

- `bun run compile` succeeds.
- `bash -n` parses `scripts/lib/test-slice.sh`, `scripts/test-everything-parallel.sh` and `scripts/check-parallel-tests.sh` without error.
- `bun run tev -- --force` passes in full.
- `systemctl --user show psphere.slice -p CPUQuotaPerSecUSec` reports the computed quota and not `infinity`.
- The `cpu.max` of the `psphere.slice` control group holds the computed quota, and `cpu.stat` in the same directory shows a non-zero `nr_throttled` after a full run, which is the proof the ceiling was actually reached and enforced.
- `systemctl --user show psphere-pool.slice -p Slice` still reports `psphere.slice`, confirming the emulators are inside the capped parent.
- A second `bun run tev` started from another worktree while the first is running lands in the same `psphere-tests.slice`, and the two together stay within the parent's quota rather than each getting it.
- Running with `PHOTOSPHERE_NO_CPU_LIMIT=1` prints the uncapped warning line and the run is not throttled.

## Notes

- The share is a policy choice, not a derived figure. 80% of 24 cores leaves about five cores for the desktop, the browser and the editors, which is what the original question asked for. The number lives in one constant so it can be changed in one place.

- A per-run cap would achieve nothing here, which is the reason for the shared slice. Capping each run at 80% of the machine still lets several concurrent runs oversubscribe it several times over. The cap has to be shared by name across worktrees, and a slice is shared by name.

- A CPU cap does not address the more damaging half of the measurement. Swap usage was 43GB, and throttling CPU makes each run take longer while holding its memory for longer, so this could make the memory pressure worse rather than better. A memory limit on `psphere.slice` is the obvious follow-up and is deliberately not in this plan, because the pool slice's own comments record that memory limits set below real usage caused constant reclaim and that the numbers were only trustworthy once measured. That measurement is its own piece of work.

- Open question for the human: should CI be capped? A hosted runner has few cores and nothing else on it, so capping there costs wall clock for no benefit. The straightforward answer is for `test_slice_supported` to return failure when `CI` is set, but that is a behaviour difference between local and CI runs and should be a decision rather than an assumption.

- Open question for the human: `ensure_test_slices` writes into `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user`, which is outside the repository. That is exactly what `ensure_pool_slice` already does, so this plan follows the established practice, but it is worth confirming that is still wanted before a second thing starts writing there.

- `nproc` is a Linux thing and is not on macOS. It is only ever reached after `test_slice_supported` has confirmed Linux, so no portable equivalent is needed, but the ordering matters and step 3 depends on it.

- Everything asserted about systemd behaviour in this plan was checked on this machine during research and is reported as checked: the slice hierarchy derived from the unit name, the `cpu` controller being delegated to the user slice, `CPUQuota` reaching `cpu.max`, and `systemd-run --scope` propagating exit status and stdio. The probe units created during that research were removed afterwards. Nothing about throttling's effect on suite timeouts was measured, which is why step 7 measures it rather than the plan asserting it.
