# run.sh

Runs Photosphere's smoke test scenarios for one platform. Invoked by the root `package.json` scripts `test:ziggy`, `test:ziggy:and` and `test:ziggy:ios`, never directly.

## Arguments

- `<platform>`: `linux`, `windows`, `macos`, `android` or `ios`. Each has a platform library in `lib/<platform>.sh` that builds the app, starts it and stops it.
- `[scenario]`: optional scenario number or full directory name, to run one scenario, as in `bun run test:ziggy:and -- 40`. `PHOTOSPHERE_SMOKE_SCENARIO=<number or name>` does the same. A run of one scenario does not record the what-changed baseline; a full run that passes does.

## Behaviour

Builds the app for the platform once, with the test hooks (the test control connection, the test mode switch and the dialog answers), and builds the Zig `psi` CLI into the run directory (`zig build -p`), which scenarios run on this host through `run_cli` and `create_database` to make their fixture databases and as the other side of a LAN share. Then runs each scenario's `test.sh` through the rolling test pool in `scripts/lib/test-pool.sh`, giving each its own temporary directory (`PHOTOSPHERE_TMP_DIR`) and a held-to timeout and a log of its own, which is printed together once the scenario finishes. A scenario that exits with 77 is skipped. On every platform the pool is as wide as `resolve_test_parallel` in `scripts/lib/test-concurrency.sh` says (`PHOTOSPHERE_TEST_PARALLEL` overrides it), as the other suites are. A platform whose scenarios each need a device caps it at the devices it has: on Android the devices that can reach the host (the devices named in `PHOTOSPHERE_ANDROID_DEVICES`, else the pool emulators on the LAN bridge, else a plugged-in device, else any other emulator such as the single one `bun run emu:and:up` starts), and on iOS the one simulator or device. A scenario claims one device under the per-device lock the pool repair also takes, and skips a device that is not responding or is off the LAN bridge, so two scenarios never share a device. It ends by printing how many scenarios passed, were skipped and failed, with the names of those that failed, and exits non-zero when any failed or when none passed. A scenario drives the running app through the test control connection; see `lib/common.sh` for what a scenario can do and what a platform library implements. Every process started is recorded as it is launched, and any still running at the end fails the run and is stopped.

Every scenario is offered to every platform. One that cannot run on a platform exits with the skipped code itself, as the MCP server and menu scenarios do on a phone and the automatic import permission scenarios do on a desktop.
