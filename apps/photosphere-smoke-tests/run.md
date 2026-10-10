# run.sh

Runs Photosphere's smoke test scenarios for one platform. Invoked by the root `package.json` scripts `test:ziggy`, `test:ziggy:and` and `test:ziggy:ios`, never directly.

## Arguments

- `<platform>`: `linux`, `windows`, `macos`, `android` or `ios`. Each has a platform library in `lib/<platform>.sh` that builds the app, starts it and stops it.
- `[scenario]`: optional scenario number or name, to run one scenario. The root scripts cannot pass an argument to this script, so `PHOTOSPHERE_SMOKE_SCENARIO=<number or name> bun run test:ziggy` does the same.

## Behaviour

Builds the app for the platform once, with the test hooks (the test control connection, the test mode switch and the dialog answers). Then runs each scenario's `test.sh` through the rolling test pool in `scripts/lib/test-pool.sh`, giving each its own temporary directory (`PHOTOSPHERE_TMP_DIR`) and a held-to timeout and a log of its own, which is printed together once the scenario finishes. A scenario that exits with 77 is skipped. On Android the pool is as wide as the number of devices that can reach the host (the pool emulators on the LAN bridge, or the devices named in `PHOTOSPHERE_ANDROID_DEVICES`), so scenarios run on all of them at once; every other platform runs one scenario at a time. A scenario claims one device under the per-device lock the mobile suite and the pool repair share, and skips a device that is not responding or is off the LAN bridge, so two scenarios never share a device. The summary line and the exit code are as before. A scenario drives the running app through the test control connection; see `lib/common.sh` for what a scenario can do and what a platform library implements. Every process started is recorded as it is launched, and any still running at the end fails the run and is stopped.

Scenarios in `desktop-only` run on Linux, Windows and MacOS only, and those in `mobile-only` run on Android and iOS only.
