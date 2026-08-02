# CLAUDE.md - android-frontend

Guidance for working in the Android frontend, especially the emulator + LAN bridge used by the mobile smoke tests.

## DO NOT touch the emulator. Ever. This is the most important rule here.

Getting the emulator started and on the LAN bridge is the human's job, not yours. You do not set it up, and you do not "fix" it.

- Never kill, restart, reboot, wipe (`-wipe-data`), or re-launch the emulator.
- Never change settings on the guest: no `svc wifi disable/enable`, no `cmd wifi ...`, no toggling airplane mode, no `adb reboot`, no reconfiguring the network.
- Never run `emu:and:up` / `emu:and:down` / `emu:and:restart` (or `emulator.sh`) to "fix" state. The emulator + bridge are the human's to manage.

Reads are fine (`adb devices`, `adb shell ip addr ...`, `status`). Changes are not. If the emulator looks wrong, **report it and stop**, do not try to repair it. Fiddling with a shared emulator once cost hours: killing a working, bridged emulator broke the very thing that was passing, and every "fix" attempt made it worse.

## Emulator + LAN bridge (`scripts/emulator.sh`)

Host-to-device LAN sharing, and the smoke tests that exercise it (`26-receive-database`, `27-receive-secret`), only work when the emulator is on a real layer-2 segment shared with the host. `scripts/emulator.sh` manages the whole lifecycle (emulator + bridge). Full explanation in `scripts/emulator.md`. **These are for the human to run, not you** (see the rule above).

- `bun run emu:and:up` - bring the hand-testing emulator up on the LAN bridge and wait until ready. Sets the bridge up automatically (prompts for sudo only for that part). It runs on its own AVD, `psphere-single`, cloned from an auto-selected base AVD (override the base with `ANDROID_AVD`). That name is how it is told apart from a pool emulator: `up` used to ask only whether *any* device was attached, so a running pool made it report success and start nothing.
- `bun run emu:and:down` - stop that emulator (the one running `psphere-single`, and only that one) and remove its tap. Leaves a running pool alone, and leaves an emulator you started yourself alone too.
- `bun run emu:and:restart` - down then up.
- `bun run emu:and:pool:up` - bring up a pool of emulators for the smoke tests (`PHOTOSPHERE_EMULATOR_COUNT`, default 5), each on its own writable clone of the base AVD and its own tap. Runs alongside `emu:and:up` without disturbing it.
- `bun run emu:and:pool:down` - stop only the pool's emulators and remove only the pool's taps.
- `bun run emu:and:pool:restart` - pool down then pool up, leaving the hand-testing emulator alone. This is how a change to the pool's memory limits takes effect, since the limits are read when an emulator starts.
- `bun run emu:and:status` - **read-only** readiness check (see below).

The bridge, DHCP and NAT are shared between the single emulator and the pool, so they are only torn down once no taps are left. Each pool emulator needs its own AVD because an AVD's disk images are single-writer; the clones are about 8KB each, since the system image lives in the SDK and is shared.

## `status`: `ready` / `not ready`

`status` prints one word on the first line and a reason on the next, and its exit code matches (0 = ready, non-zero = not). It reports the one thing that matters, whether the guest's `wlan0` has a `192.168.55.x` address, which is exactly what the smoke tests require. It is a read-only check; it never changes the emulator.

It prints one line per attached device saying whether that device is on the bridge, then a verdict:

- `ready` / `N emulator(s) started and on the lan bridge` - good to run `test:and`, which will use all N.
- `not ready` / `emulator not started` - no emulator/device attached.
- `not ready` / `no emulator is on the lan bridge` - emulators up, but none has a `192.168.55.x` address on `wlan0`.

The guest address is timing-dependent (wifi associates/de-associates, adb is busy during a test), so `status` retries a few times. It is still a hint: the definitive check is running `bun run test:and`.

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
