# CLAUDE.md - android-frontend

Guidance for working in the Android frontend, especially the emulator + LAN bridge used by the mobile smoke tests.

## The line is at the privileges, not at the emulator

The bridge, the taps, the DHCP server and the whole-pool teardown are the human's. Everything that needs root is the human's. You have three commands that need no privileges at all, restart one emulator at a time, and respect the locks a running test holds, and those you may run.

**First: when the monitor is running, a broken emulator is not yours to fix.** `bun run emu:and:pool:monitor` repairs every unhealthy pool emulator by itself, one at a time, within seconds of it going bad, so a repair you start is a second one racing it. Check before you reach for `emu:pool:repair`, and do not guess, because the human starts and stops the monitor without announcing it:

```
flock -n /tmp/photosphere-emulator-pool-monitor.lock true
```

Exit 1 means a monitor holds the lock and is running: say the emulator is broken, say the monitor will pick it up within seconds, and leave it alone. Exit 0 means no monitor is running and the repair is yours to run. The probe changes nothing; it takes the lock only long enough to find out and gives it straight back.

**You may run these:**

- `bun run emu:and:pool:status` - read-only, and the only way to say whether the pool is up.
- `bun run --filter=android-frontend emu:pool:diagnose` - read-only. Everything readable about every pool emulator: unit state, CPU time, whether it holds `/dev/kvm` and a tap, listening sockets, AVD lock pids, log tail.
- Reading the monitor's logs, which is where to start on any question about what the pool did earlier. `/tmp/photosphere-emulator-pool-monitor.log` holds every line the monitor said plus a summary a minute (healthy count, CPU, memory, swap, each emulator's state), and `/tmp/photosphere-emulator-pool-monitor-repairs.log` holds each repair's own output. Both roll at 4MB keeping one `<name>.1`. `diagnose` says how the pool is now; these say how it got there.
- `bun run --filter=android-frontend emu:pool:repair` - restarts broken pool emulators, one at a time. Never touches a tap or the bridge, never runs sudo, never prompts, and skips any emulator a test run is using. `--index N` for one, `--all` for every one.
Not `bun run emu:and:pool:monitor`. That brings the pool up when it is not there, which needs sudo for the bridge and the taps, and it runs until stopped. It is the human's.

Repair and diagnose are written out in full above because only the status and monitor entries exist in the root `package.json`; a shortened form of the other two sends you looking for a script that is not there.

**You still may not:**

- Run `emu:and:up`, `emu:and:down`, `emu:and:restart`, `emu:and:pool:up`, `emu:and:pool:down` or `emu:and:pool:restart`.
- Create or remove a tap or the bridge, or run `sudo` for any reason.
- Reconfigure a guest: no `svc wifi disable/enable`, no `cmd wifi ...`, no toggling airplane mode, no `adb reboot`.
- Kill, wipe or re-launch an emulator by hand. `emu:pool:repair` is how an emulator gets restarted, because it takes the device lock first; a bare `adb emu kill` does not, and can take a device out from under a running test.

If something is wrong that these commands do not fix, **report it and stop**. Fiddling with a shared emulator once cost hours: killing a working, bridged emulator broke the very thing that was passing, and every "fix" attempt made it worse.

## Emulator + LAN bridge (`scripts/emulator.sh`)

Host-to-device LAN sharing, and the smoke tests that exercise it (`26-receive-database`, `27-receive-secret`), only work when the emulator is on a real layer-2 segment shared with the host. `scripts/emulator.sh` manages the whole lifecycle (emulator + bridge). Full explanation in `scripts/emulator.md`. **The ones below are for the human to run, not you**, except where the section above says otherwise.

- `bun run emu:and:up` - bring the hand-testing emulator up on the LAN bridge and wait until ready. Sets the bridge up automatically (prompts for sudo only for that part). It runs on its own AVD, `psphere-single`, cloned from an auto-selected base AVD (override the base with `ANDROID_AVD`). That name is how it is told apart from a pool emulator: `up` used to ask only whether *any* device was attached, so a running pool made it report success and start nothing.
- `bun run emu:and:down` - stop that emulator (the one running `psphere-single`, and only that one) and remove its tap. Leaves a running pool alone, and leaves an emulator you started yourself alone too.
- `bun run emu:and:restart` - down then up.
- `bun run emu:and:pool:up` - bring up a pool of emulators for the smoke tests (`PHOTOSPHERE_EMULATOR_COUNT`, default 5, defined in `scripts/emulator-config.sh`), each on its own writable clone of the base AVD and its own tap. Runs alongside `emu:and:up` without disturbing it.
- `bun run emu:and:pool:down` - stop only the pool's emulators and remove only the pool's taps.
- `bun run emu:and:pool:restart` - pool down then pool up, leaving the hand-testing emulator alone. This is how a change to the pool's memory limits takes effect, since the limits are read when an emulator starts. It also resets each pool emulator's data partition to baseline, by starting it with `-wipe-data`, which is how a change to the partition size takes effect (the partition is sized when userdata is created, so a bigger number does nothing to an emulator that already has one) and how a partition that has filled up gets cleared. The first `test:and` afterwards reinstalls the app on every emulator, because the wipe removes the checksum stamp it compares against. **You still do not run this**, per the rule at the top of this file; it is the human's.
- `bun run emu:and:status` - **read-only** readiness check (see below).
- `bun run --filter=android-frontend emu:pool:repair` - restart the pool emulators that are broken, one at a time, leaving the bridge and the taps exactly as they are. This is the repair that needs no root: `pool-restart` cannot run unattended because it begins by removing the pool's taps, which needs sudo. Useless when the taps or the bridge are gone (after a reboot, or after `pool-down`); only `pool-up` can make those.
- `bun run --filter=android-frontend emu:pool:diagnose` - **read-only**. Everything readable about every pool emulator. Run this rather than guessing when an Android run is unexplainedly slow or an emulator looks wrong.
- `bun run emu:and:pool:monitor` - the one command for the pool, and it takes no arguments. It brings the pool up when it is not there (which asks for sudo only when the bridge or the taps have to be made), repairs every emulator that is not healthy, and then keeps doing that as they go bad, one at a time and never one a test is using. It also recycles a healthy emulator that has been up over 12 hours while the rest are healthy. On a terminal it shows the table of emulators with CPU, memory and swap graphs; redirected to a file it prints one line per pass. Either way it writes the two rolling logs listed above, so what it did is readable afterwards. One monitor per machine. This replaces `emu:and:health`, which is gone.

The bridge, DHCP and NAT are shared between the single emulator and the pool, so they are only torn down once no taps are left. Each pool emulator needs its own AVD because an AVD's disk images are single-writer; the clones are about 8KB each, since the system image lives in the SDK and is shared.

## `status`: `ready` / `not ready`

`status` prints one word on the first line and a reason on the next, and its exit code matches (0 = ready, non-zero = not). It reports the one thing that matters, whether the guest's `wlan0` has a `192.168.55.x` address, which is exactly what the smoke tests require. It is a read-only check; it never changes the emulator.

It prints one line per attached device saying whether that device is on the bridge, then a verdict:

- `ready` / `N emulator(s) started and on the lan bridge` - good to run `test:and`, which will use all N.
- `not ready` / `emulator not started` - no emulator/device attached.
- `not ready` / `no emulator is on the lan bridge` - emulators up, but none has a `192.168.55.x` address on `wlan0`.

The guest address is timing-dependent (wifi associates/de-associates, adb is busy during a test), so `status` retries a few times. It is still a hint: the definitive check is running `bun run test:and`.

## `bun run emu:and:pool:status`: the pool alone, as an exit code

`status` above answers a wider question than the pool. It counts every attached emulator that is on the bridge, including the single hand-testing one, so it says `ready` when the pool is down and only `psphere-single` is up. `bun run emu:and:pool:status` (`scripts/android-pool-status.sh`) filters to pool emulators by asking each device which AVD it is running, and exits 0 when at least one of them is on the LAN bridge and 1 when none is. Add `-- --quiet` for the exit code alone, for use in a condition. It is read-only and never changes anything.

A partial pool exits 0, because `test:and` can run on what is left, but it says so (`3 of 5 pool emulator(s) on the LAN bridge`). Emulators leave this pool by being killed for using too much memory, so a count that has dropped is the first sign of that.

**Never state whether the pool is up or down without running this first.** Every time that has been guessed at it has been wrong, always the same way: a reading taken earlier in the session and repeated later as though it were current. The human starts and stops emulators without announcing it, so a reading is stale the moment after it is taken. Run the check at the point the answer is needed.

## `test:and` gates on readiness and shares the emulators

`bun run test:and` runs `apps/smoke-tests/run.sh`. Several runs can go at once: the emulators are a shared pool rather than something one run reserves.

- **Fails immediately if the emulator is not `ready`** (run.sh runs the same readiness check as `bun run emu:and:status`). It will not boot, build, or touch anything when not ready, it exits with the reason. You set the emulator up; the test just checks and runs. The one exception is `PHOTOSPHERE_NO_LAN_BRIDGE=1`, which declares that this run cannot have a bridge at all: it then requires only a started emulator, and `26-receive-database` / `27-receive-secret` log a `SKIP` line instead of failing. The release workflow sets it because its emulator is booted by an action that attaches no tap device. Do not set it locally: without a bridge you lose exactly the two tests that cover host-to-device LAN sharing.
- **Uses the pool, and only the pool, when one is up**, so a hand-testing emulator is left alone. With no pool running it falls back to whatever bridge-ready emulator there is, which is what makes a single hand-started one work. Pin a run to particular devices with `PHOTOSPHERE_ANDROID_DEVICES="emulator-5556 emulator-5558"`.
- **Takes an emulator per test, not per run**, under a `flock` on `/tmp/photosphere-android-device-<serial>.lock`, and hands it back immediately afterwards. Each suite is held to an even split of the emulators between the suites currently running, so one run alone uses all of them and three runs get a third each. A run with nothing free waits, giving up after `PHOTOSPHERE_DEVICE_CLAIM_TIMEOUT` (default 1800s).
- **Reinstalls the app when another checkout's build is on the device.** Every worktree builds the same `applicationId`, so a run compares the installed APK's checksum against its own before each test and puts its build back if they differ. Without it a run silently tests another worktree's code.

The old whole-run lock (`apps/smoke-tests/android-lock.sh`, `/tmp/photosphere-test-and.lock`) is no longer used by `test:and`, because it let only one run proceed at a time. The script and its stress test remain.

Lock commands (run from repo root or `apps/smoke-tests`):

- `bun run test:and:lock` - acquire and hold the lock until Ctrl-C, for exercising the locking on its own.
- `bun run test:and:lock-status` - definitive verdict via a non-blocking `flock` probe (not a guess): `free`, `locked (...)`, or `stale (...)` (exit 1 only for `stale`).
- `bun run test:and:unlock` - remove a stale lock; refuses if a run is actually in progress.

The locking is covered by an automated stress test, `apps/smoke-tests/android-lock.test.sh` (run directly; the release workflow runs it too).

## Lessons (do not repeat these)

- **Never conclude "the bridge is broken" from a proxy check, and never stop/give up on one.** Prove it by running `test:and`. A pid-file/`ss`/`dnsmasq` reading is not evidence.
- **A booted guest keeps its DHCP lease after dnsmasq stops.** So "DHCP server not running" does not mean LAN sharing is broken; only a freshly booting guest needs the server.
- **`wlan0` showing no address, or `NO-CARRIER`, is often transient** (association gap, adb busy), not proof the emulator is off the bridge.
- **Don't restate a diagnosis as fact.** If you claimed something is blocked, re-verify by running the real thing before repeating it.
- **Check the pool before starting anything that uses it.** `bun run emu:and:pool:status`, at the moment you need the answer, not a reading taken earlier in the session.
- **Never stack the Android suite against other suites by hand.** On 2026-08-09 the Android suite was run beside twelve other lanes on a machine already short of memory, and all five pool emulators died with SIGSEGV. `test:and` now refuses to start below `PHOTOSPHERE_MIN_AVAILABLE_MB` (4096) of available memory, which is a floor and not permission to run at 4.1GB.
- **An unexplained slow Android run is a signal, not something to wait out.** Run `bun run --filter=android-frontend emu:pool:diagnose`. An emulator thrashing on memory stays listed by adb and accepts connections while answering nothing, so it looks present and costs every test its full timeout.
- **Never assert what killed an emulator before reading `systemctl --user status`.** Four causes were proposed during the 2026-08-09 recovery and all four were wrong. `Result: core-dump` in the unit is the difference between a crash and a kill, and it takes one command to read.
