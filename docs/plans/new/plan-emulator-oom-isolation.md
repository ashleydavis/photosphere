# Stop an out-of-memory kill of the terminal taking the emulator pool with it

## Overview

The Android emulator pool is launched from whatever terminal the human ran `bun run emu:and:pool` in, and every emulator ends up in that terminal's systemd cgroup. When the machine ran out of memory, `systemd-oomd` chose that cgroup to reclaim and killed everything inside it: `app-gnome-org.wezfurlong.wezterm-2811860.scope: systemd-oomd killed 354 process(es) in this unit`. The whole pool died, not because the emulators were the memory hog but because they were sitting in the scope that was chosen. The next `bun run test:and` then failed with `emulator not started`, which reads as a test failure and is not one. `start_emulator_bg` in `apps/android-frontend/scripts/emulator.sh` already calls `setsid`, but that only detaches the controlling terminal and session; a process inherits its cgroup regardless, so it does nothing for this. This plan launches each emulator into its own transient systemd user scope so it is a sibling of the terminal's scope rather than a member of it, and asks `systemd-oomd` to prefer other targets. It does not reduce memory use and does not make an emulator immune; it stops one unrelated process tree taking the pool down with it.

## Issues

## Steps

1. **Extract the launch command so it can be asserted without starting an emulator.** In `apps/android-frontend/scripts/emulator.sh`, add a function `emulator_launch_argv()` above `start_emulator_bg()` (currently at line 584). It takes the emulator binary path, the AVD name, the tap interface name and the log suffix, and prints the full argv that should be executed, one argument per line, without running anything. It contains the branch: when a systemd user session is usable it prints a `systemd-run` invocation wrapping the emulator; otherwise it prints the existing `setsid` invocation. Add a second function `systemd_scopes_available()` that returns success when `XDG_RUNTIME_DIR` is set and non-empty and `systemd-run` is on `PATH`, so the branch has one named condition that a test can control. Both need a `#` comment block above them explaining intent, per the repo's style. `bash -n` must pass on the file and the existing harness tests must still pass before this step is done.

2. **Use the extracted argv in `start_emulator_bg`.** Change `start_emulator_bg()` in `apps/android-frontend/scripts/emulator.sh` so that instead of the literal `setsid "$emulator" -avd ...` at line 612 it reads the argv from `emulator_launch_argv` into an array and executes that array in the background, keeping the existing `>"/tmp/psphere-emulator-$log_suffix.log" 2>&1 </dev/null &` redirection unchanged. Behaviour on a machine with no systemd user session must be byte-for-byte what it is today. `bash -n` must pass.

3. **Give the systemd branch its scope settings.** In `emulator_launch_argv()`, the systemd branch must produce `systemd-run --user --scope --quiet --collect --unit=psphere-emulator-<log_suffix> --property=ManagedOOMPreference=avoid -- <emulator> -avd <avd> -no-snapshot -no-boot-anim -wifi-tap <netcard>`. One scope per emulator, named from the log suffix, so a five-emulator pool is five sibling scopes and not one shared one. `--collect` so a transient unit is garbage collected when the emulator exits and a later run of the same index does not fail with "unit already exists". Explain in a comment above the branch why `setsid` was not enough (cgroup inheritance), and that `ManagedOOMPreference=avoid` is a preference and not immunity.

4. **Add `scripts/emulator-launch.test.sh` under `apps/android-frontend/`.** Follow the pattern of `apps/smoke-tests/timeout.test.sh`: a `check` helper comparing expected and actual, a `WORK` directory from `mktemp -d` removed by an `EXIT` trap, a `fails` counter, and a non-zero exit when anything failed. It sources `emulator.sh` in a mode that defines the functions without executing a command (see step 5), then asserts the argv `emulator_launch_argv` prints for both branches, driving the branch by setting and unsetting `XDG_RUNTIME_DIR` and by putting a stub `systemd-run` on, or off, a `PATH` that holds nothing else. It must start no emulator and must not call `systemd-run` for real.

5. **Make `emulator.sh` sourceable for the test.** Check whether `apps/android-frontend/scripts/emulator.sh` currently runs a command on source. If it dispatches on `$1` unconditionally at the bottom, guard that dispatch so sourcing the file defines the functions without acting, using the same idiom the other testable harness scripts in this repository use (compare `apps/smoke-tests/lib/common.sh`, which `timeout.test.sh` sources). Do not change the behaviour of running the script normally: `emulator.sh up`, `pool`, `down`, `pool-down`, `restart` and `status` must behave exactly as before.

6. **Register the test in CI.** In `.github/workflows/release.yml`, add a step to the `mobile-harness-tests` job (which currently runs `android-lock.test.sh`, `runner.test.sh` and `timeout.test.sh`) that runs `bash ./apps/android-frontend/scripts/emulator-launch.test.sh`. It needs no device, no emulator and no Android SDK, so it belongs in that job and runs in seconds.

7. **Document it.** Add a short section to `apps/android-frontend/scripts/emulator.md` covering: that each emulator runs in its own transient systemd scope on Linux; why (`setsid` does not change the cgroup, and `systemd-oomd` reclaims per cgroup); that this does not stop the emulator being killed if it is genuinely the memory hog; how to see the scopes (`systemctl --user list-units 'psphere-emulator-*'`); and that macOS falls back to the previous `setsid` launch. Keep it to the length of the existing sections in that file rather than restating this plan.

## Unit Tests

In `apps/android-frontend/scripts/emulator-launch.test.sh`:

- `systemd_scopes_available` returns success when `XDG_RUNTIME_DIR` is set and a `systemd-run` stub is on `PATH`.
- `systemd_scopes_available` returns failure when `XDG_RUNTIME_DIR` is unset, even with `systemd-run` present.
- `systemd_scopes_available` returns failure when `systemd-run` is absent, even with `XDG_RUNTIME_DIR` set. This is the macOS path.
- `emulator_launch_argv` prints the `systemd-run --user --scope` form when scopes are available, including `--collect`, the per-emulator `--unit=psphere-emulator-<suffix>` name and `--property=ManagedOOMPreference=avoid`.
- `emulator_launch_argv` prints the `setsid` form, unchanged from today, when scopes are not available.
- `emulator_launch_argv` passes the emulator flags through in both branches: `-avd`, `-no-snapshot`, `-no-boot-anim` and `-wifi-tap <netcard>` with the values it was given.
- `emulator_launch_argv` derives a distinct unit name per log suffix, so two pool indices do not collide on one scope name.

## Smoke Tests

- Add a case to `apps/android-frontend/scripts/emulator-launch.test.sh` that runs a stub "emulator" (a short shell script printing `/proc/self/cgroup`) through the real `systemd-run` line the systemd branch produces, and asserts the reported cgroup path ends in `psphere-emulator-<suffix>.scope` and differs from the test process's own cgroup. Skip this case with a printed `SKIP` line when `systemd_scopes_available` is false, so it is a no-op on macOS and in containers rather than a failure. This is the only check that proves the actual defect is fixed; everything else asserts the command string.
- Add a case asserting the transient unit does not survive the stub exiting, so `--collect` is doing its job and a second pool start cannot fail with "unit already exists". Skip it on the same condition.
- The existing `bun run test:and` suite is the end-to-end check that a real pool still starts and is reachable, but it needs a human-started pool and is not run by this plan.

## Verify

- `bash -n apps/android-frontend/scripts/emulator.sh` passes.
- `bash -n apps/android-frontend/scripts/emulator-launch.test.sh` passes.
- `bash ./apps/android-frontend/scripts/emulator-launch.test.sh` passes with no failures.
- `bash ./apps/smoke-tests/android-lock.test.sh`, `bash ./apps/smoke-tests/runner.test.sh` and `bash ./apps/smoke-tests/timeout.test.sh` all still pass, proving the sourceability change in step 5 broke nothing.
- `bun run compile` clean and `bun run test` passing.
- `git diff` on `apps/android-frontend/scripts/emulator.sh` shows only the launch path and the two new functions changed, with no change to bridge setup, DHCP, NAT, AVD creation, `stop_emulator`, `cmd_pool_down` or `cmd_status`.
- The step 7 documentation names only commands that exist, and every relative link added resolves to a file that exists.

## Notes

- **The evidence this is built on.** `journalctl --user` recorded `app-gnome-org.wezfurlong.wezterm-2811860.scope: systemd-oomd killed 354 process(es) in this unit` followed by `Failed with result 'oom-kill'`. At the time swap was at 64 GB of 65 and RAM at 42 GB of 62, with roughly 8.8 GB held by 170 stale Electron processes left behind by earlier smoke-test runs across three worktrees. The emulators were about 23 GB of legitimate use.
- **The approach was verified before this plan was written.** `systemd-run --user --scope --quiet --collect --unit=... --property=ManagedOOMPreference=avoid -- <cmd>` was run on the target machine: the child reported `/user.slice/user-1000.slice/user@1000.service/app.slice/psphere-emulator-probe.scope` against the shell's `.../app.slice/app-gnome-org.wezfurlong.wezterm-*.scope`, confirming a sibling cgroup rather than a nested one, and `ManagedOOMPreference=avoid` was accepted on a scope.
- **This does not fix the underlying problem, which is memory exhaustion.** It stops one collateral effect. The machine still runs out of memory when a full parallel test set, six emulators and a pile of leaked Electron processes are live at once. Two separate things would actually address that: stopping the smoke suites leaking processes, and not running the heaviest suites concurrently. Both are out of scope here and neither is planned yet.
- **`ManagedOOMPreference=avoid` is a preference, not immunity.** If an emulator genuinely is the largest consumer under pressure it can still be killed, and that is correct behaviour. `omit` would exclude it from selection entirely and was deliberately not chosen: it makes a hard kernel OOM kill more likely, which is worse than a targeted one.
- **`setsid` is kept for the fallback and is not redundant.** On a machine with no systemd user session it is still what stops a terminal closing from sending `SIGHUP` to the emulator. The systemd branch does not need it because the scope already gives the process its own cgroup, though it does still inherit the controlling terminal; if closing the terminal is later found to kill a scoped emulator, that is a follow-up, not something to fix speculatively here.
- **macOS cannot exercise the systemd branch at all.** The unit tests cover the argv it would produce, and the cgroup smoke test skips. That asymmetry is unavoidable and should be stated in the step 7 documentation rather than hidden.
- **Do not start, stop or restart any emulator while implementing this.** `apps/android-frontend/CLAUDE.md` is explicit that the emulator and bridge are the human's to manage. Every check in this plan runs against stubs, and the one live check starts a shell script inside a scope, never an emulator.
- **Check `cmd_pool_down` and `stop_emulator` still work unchanged.** Both stop emulators with `adb emu kill` rather than by pid or unit, so a scope should make no difference to them, but this is worth confirming by reading rather than assuming, since a transient scope that outlives its process would leave `systemctl --user list-units` cluttered.
