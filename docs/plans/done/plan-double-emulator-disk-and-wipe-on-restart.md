# Double the emulator data partition and reset it on every pool restart

## Overview

The pool emulators have run out of disk. Each of the five active AVDs holds a `userdata-qemu.img.qcow2` of 6,442,909,696 bytes, which is exactly the `disk.dataPartition.size=6G` written into `config.ini` by `create_base_avd` in `apps/android-frontend/scripts/emulator.sh`, so every one of them is at its limit. A full data partition makes the package manager refuse the install with `INSTALL_FAILED_INSUFFICIENT_STORAGE`, and a suite that does not notice carries on testing whichever build was already on the device, which is why `scripts/android-pool-status.sh` now reports free space. Restarting the pool does not help, and cannot: `pool-down` stops the emulators but leaves the AVD directories alone, `clone_avd` returns early when a clone already exists, and `-no-snapshot` forces a cold boot without touching userdata, so `pool-up` reattaches the same full overlay it left behind. This plan makes two changes that only work together. It doubles the partition to 12G, and it makes `pool-restart` start each emulator with `-wipe-data` so the overlay is recreated from the system image. The size change alone does nothing to an existing AVD, because the partition is sized when `userdata-qemu.img` is first created, so without the wipe the new number would sit in `config.ini` and change nothing at all.

## Issues

## Steps

**Standing constraint.** The agent must never start, stop, restart or wipe an emulator, per `apps/android-frontend/CLAUDE.md`. That rule is about the agent's own actions and does not stop it writing the code that performs a wipe when the human runs `pool-restart`. Every step below is verified without an emulator, by pointing `ANDROID_AVD_HOME` at a temporary directory, which `avd_home()` in `apps/android-frontend/scripts/emulator.sh` already honours. Shell scripts in this repository get no unit tests and no `*.test.sh` files, per `CLAUDE.md`.

1. **Name the partition size once instead of writing it inline.** In `apps/android-frontend/scripts/emulator.sh`, add a constant `AVD_DATA_PARTITION_SIZE="12G"` beside the other pool constants near `POOL_UNIT_GLOB` (currently around line 142), with a `#` comment block above it recording that it was 6G, that all five pool AVDs reached that limit, and that the size only takes effect on an AVD whose userdata is created fresh. Change the `disk.dataPartition.size=6G` line in the `config.ini` heredoc inside `create_base_avd` (currently line 487) to use the constant. `bash -n apps/android-frontend/scripts/emulator.sh` must pass.

2. **Make the size reach AVDs that already exist.** `clone_avd` returns early when the clone's `config.ini` is already there, so an existing pool AVD keeps whatever size it was cloned with and step 1 would never reach it. Add a function `ensure_avd_data_partition_size()` to `apps/android-frontend/scripts/emulator.sh` above `clone_avd`, taking an AVD name. It reads that AVD's directory from its `.ini`, and rewrites the `disk.dataPartition.size` line in its `config.ini` to `AVD_DATA_PARTITION_SIZE` when it differs, adding the line when it is absent. It prints what it changed and leaves everything else in the file untouched. It must not touch any file when the value already matches, so a second call is a no-op. Give it a `#` comment block explaining that config.ini is the input to the next cold boot and that the running emulator's own `hardware-qemu.ini` is regenerated at launch, so editing config.ini between runs is what takes effect.

3. **Call the size check on the way up.** In `cmd_pool_up` in `apps/android-frontend/scripts/emulator.sh` (currently around line 939), call `ensure_avd_data_partition_size` for each pool AVD immediately after the `clone_avd` call at line 951, so a clone that already existed is brought up to the current size before it starts. Do the same for `SINGLE_AVD_NAME` in the single-emulator path at line 919, so the hand-testing emulator does not drift to a different size from the pool.

4. **Extract the emulator argv so the wipe can be asserted without starting anything.** In `apps/android-frontend/scripts/emulator.sh`, add a function `emulator_launch_argv()` above `start_emulator_bg`. It takes the emulator binary path, the AVD name, the tap interface name and a flag saying whether to wipe, and prints the argv one argument per line without running anything. It contains the existing flags (`-avd`, `-no-snapshot`, `-no-boot-anim`, `-gpu swiftshader_indirect`, `-wifi-tap`) and appends `-wipe-data` when the flag is set. This exists so the next step's behaviour can be checked by reading the printed argv rather than by starting an emulator, which the agent may not do. Note that `plan-emulator-oom-isolation.md` proposes a function of the same name for a different purpose; if that plan has landed first, extend the existing function rather than adding a second one.

5. **Have `start_emulator_bg` use the extracted argv and accept the wipe flag.** Change `start_emulator_bg` in `apps/android-frontend/scripts/emulator.sh` (the `systemd-run` invocation currently at line 803) so the emulator arguments come from `emulator_launch_argv` rather than being written inline, and add a parameter carrying whether to wipe. Every `systemd-run` property already there (`--slice`, `MemoryHigh=8G`, `MemorySwapMax=2G`, the `StandardOutput` and `StandardError` file targets, the `--setenv` arguments) stays exactly as it is. With the wipe flag unset the argv must be byte-for-byte what it is today.

6. **Wipe on restart and only on restart.** Add an optional `--wipe` argument to `cmd_pool_up` in `apps/android-frontend/scripts/emulator.sh`, which it passes through to `start_emulator_bg` for each emulator it starts. Change `cmd_pool_restart` (currently line 1126) to call `cmd_pool_up --wipe`. A plain `bun run emu:and:pool:up` keeps its current behaviour and does not wipe, because it is what brings a pool back after a crash and losing the installed app on that path would be a surprise. Update the `case` at the bottom of the file so `pool-up` forwards any arguments it was given, and update the usage text so both commands say what they do to userdata.

7. **Say what the wipe costs, in the script and in the docs.** A wipe removes `/data/local/tmp/psphere-apk.sha`, the stamp `android_ensure_apk` in `apps/smoke-tests/lib/android.sh` compares against, so the first `test:and` after a restart reinstalls the APK on every emulator. That is once per restart rather than once per run, and it is the behaviour commit `a01f52f2` removed from the per-run path, so it is worth naming rather than leaving to be rediscovered. Record it in the comment block above `cmd_pool_restart` and in `apps/android-frontend/scripts/emulator.md`, alongside a note that a wipe is what makes a partition size change take effect.

8. **Update the Android frontend's own guidance.** In `apps/android-frontend/CLAUDE.md`, update the `emu:and:pool:restart` line in the command list (it currently says only that it is how a change to the pool's memory limits takes effect) to say that it also resets each emulator's data partition to baseline and that this is how a disk-size change takes effect. Keep the existing rule that the agent does not run it.

9. **Report the stale pool AVDs rather than deleting them.** `avd_home()` currently holds `psphere-pool-0` through `psphere-pool-9`, but only five emulators run. The five unused directories hold roughly 14GB between them. The agent must not delete them: they are the human's files, outside the repository, and removing them is hard to reverse. Instead have the agent report their names and sizes and stop, leaving the decision to the human. If the human approves removal in the message being acted on, the agent may then remove only directories matching the pool prefix whose index is at or above the running pool size, and only after confirming with `bun run emu:and:pool:status` that no emulator is running.

10. **Check the host has room for the larger partitions.** Five emulators at 12G is 60G of worst-case overlay against the 6G each they use now, on top of the base and single AVDs. Add the current figures to `apps/android-frontend/scripts/emulator.md`: the measurement taken while writing this plan was 57G total under the AVD directory with 258G free on the filesystem holding it. The qcow2 overlays are sparse and grow only as they are written, so the doubling costs nothing until it is used, but the ceiling doubles and that is worth having written down.

## Unit Tests

None. Every change in this plan is in `apps/android-frontend/scripts/emulator.sh`, which is shell, and this repository does not unit test shell scripts or add `*.test.sh` files, per `CLAUDE.md`. The rule requiring a test per changed function does not apply to shell.

What replaces them is the verification below, which exercises the two new functions for real against a temporary AVD tree rather than stubbing anything.

## Smoke Tests

- `bun run test:and` must pass in full after the change. It is the end-to-end coverage for whether the emulators are still usable, and it exercises `android_ensure_apk` reinstalling onto a wiped device.
- No new smoke test is added for the wipe itself. A test for it would have to restart the pool, and the pool belongs to the human; the suite refuses to touch it by design. The argv check in the verification section is what covers whether `-wipe-data` is passed.

## Verify

1. `bash -n apps/android-frontend/scripts/emulator.sh` passes.
2. `bun run compile` exits 0.
3. `bun run test` passes.
4. With `ANDROID_AVD_HOME` pointed at a temporary directory containing a hand-written AVD whose `config.ini` says `disk.dataPartition.size=6G`, calling `ensure_avd_data_partition_size` rewrites it to `12G`, reports what it changed, and leaves every other line of the file identical (compare with `cmp` against a copy taken beforehand).
5. Calling `ensure_avd_data_partition_size` a second time against the same AVD changes nothing and prints nothing, and the file's modification time is unchanged (`stat -c %Y`).
6. `ensure_avd_data_partition_size` against an AVD whose `config.ini` has no `disk.dataPartition.size` line adds it.
7. `emulator_launch_argv` without the wipe flag prints exactly the argument list the script produces today, confirmed by comparing against the argv built from the version of the file at `HEAD`.
8. `emulator_launch_argv` with the wipe flag prints the same list plus `-wipe-data`.
9. `grep -n 'cmd_pool_up --wipe' apps/android-frontend/scripts/emulator.sh` matches inside `cmd_pool_restart`, and no other caller of `cmd_pool_up` passes it.
10. `bun run emu:and:pool:status` exits 0 before and after, with the same number of emulators on the bridge, proving nothing in this work disturbed the running pool.
11. `bun run test:everything -- --force` passes, which is the canonical check for this repository and covers the mobile suites.

The one thing the agent cannot verify is the wipe actually happening, because that needs a pool restart and the agent may not perform one. After the checks above pass, report that and stop, naming what the human would need to run (`bun run emu:and:pool:restart`) and what to look for (`du -sh` on a pool AVD directory dropping from about 6.1G, and `bun run emu:and:pool:status` reporting no emulator low on space).

## Notes

**The two changes are one change.** Doubling `disk.dataPartition.size` has no effect on an AVD whose `userdata-qemu.img` already exists, because the partition is sized when that file is created. Landing the size bump without the wipe would leave `config.ini` saying 12G while every emulator carried on with the same full 6G overlay, which looks like a fix and is not one. This is also why step 2 exists: `clone_avd` returns early for an existing clone, so even a fresh `pool-up` would not have picked the new size up.

**Measurements taken while writing this plan.** Each of `psphere-pool-0` through `psphere-pool-4` occupies 6.1G, with `userdata-qemu.img.qcow2` at 6,442,909,696 bytes, which is the 6G partition limit exactly. `psphere-pool-5` through `psphere-pool-9` are leftovers from a larger pool at 2.6G to 2.9G each. `psphere-base` is 5.3G and `psphere-single` is 7.1G. The AVD directory totals 57G on a filesystem with 258G free.

**Why `-wipe-data` rather than deleting the qcow2 files.** Removing `userdata-qemu.img.qcow2`, `cache.img.qcow2`, `encryptionkey.img.qcow2` and the `snapshots` directory by hand would appear to do the same job, but it is a hand-rolled version of something the emulator already does correctly, and getting the set of files wrong leaves an AVD that boots into an inconsistent state rather than failing loudly. The vendor flag is the supported path and stays correct when the emulator changes what it keeps where.

**Why plain `pool-up` does not wipe.** `pool-up` is what brings the pool back after emulators have crashed, which happens on this machine because of the memory leak (`docs/plans/new/plan-find-and-fix-emulator-memory-leak.md`). Wiping on that path would throw away the installed app every time a crash is recovered from, turning a recovery into a full reinstall. `pool-restart` is the deliberate act and is the right place for a deliberate reset.

**The reinstall after a restart is expected, not a regression.** Commit `a01f52f2` stopped `test:and` reinstalling an unchanged APK at the top of every run, saving 585MB of writes per run. A wipe removes the stamp that makes that possible, so the first run after a restart installs on all five emulators again. That is once per restart, not once per run, and the saving `a01f52f2` made is untouched from the second run onwards.

**This does not fix the reason the disks filled.** Something is writing enough to fill a 6G partition, and doubling it to 12G buys time rather than answering why. The after-test cleanup added in commit `2b1dd131` clears the app's data when each test finishes, so what remains should be small; whether it is has never been measured, and step 10 of `docs/plans/new/plan-find-and-fix-emulator-memory-leak.md` is where that measurement belongs. If the partitions fill again at 12G, the size is not the problem.

**Open question this plan does not settle.** Whether the full disk and the host memory leak share a cause is unknown. They are separate symptoms with separate evidence: the disk is guest-side and visible in the qcow2 overlay, the memory growth is host-side in the QEMU process with the guest's RAM fixed at 2048M. They are treated as two problems here because nothing links them yet.
