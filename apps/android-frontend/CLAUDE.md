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

- `bun run emu:and:up` - bring the emulator up on the LAN bridge and wait until ready. Sets the bridge up automatically (prompts for sudo only for that part). AVD auto-selected (override with `ANDROID_AVD`).
- `bun run emu:and:down` - stop the emulator and tear the bridge down.
- `bun run emu:and:restart` - down then up.
- `bun run emu:and:status` - **read-only** readiness check (see below).

## `status`: `ready` / `not ready`

`status` prints one word on the first line and a reason on the next, and its exit code matches (0 = ready, non-zero = not). It reports the one thing that matters, whether the guest's `wlan0` has a `192.168.55.x` address, which is exactly what the smoke tests require. It is a read-only check; it never changes the emulator.

- `ready` / `emulator is started and on the lan bridge` - good to run `test:and`.
- `not ready` / `emulator not started` - no emulator/device attached.
- `not ready` / `not on lan bridge` - emulator up, but its `wlan0` has no `192.168.55.x` address.

The guest address is timing-dependent (wifi associates/de-associates, adb is busy during a test), so `status` retries a few times. It is still a hint: the definitive check is running `bun run test:and`.

## `test:and` gates on readiness, and the lock is its own script

`bun run test:and` runs `apps/smoke-tests/run.sh` **wrapped in the lock** (`apps/smoke-tests/android-lock.sh`, the single, definitive owner of the run-lock, every acquisition goes through it).

- **Fails immediately if the emulator is not `ready`** (run.sh runs the same readiness check as `bun run emu:and:status`). It will not boot, build, or touch anything when not ready, it exits with the reason. You set the emulator up; the test just checks and runs.
- **Serialized by one `flock` lock** (`/tmp/photosphere-test-and.lock`), so two runs never collide on the one emulator. Generous timeout (`PHOTOSPHERE_ANDROID_LOCK_TIMEOUT`, default 1800s); it announces the wait and gives up rather than hang.

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
