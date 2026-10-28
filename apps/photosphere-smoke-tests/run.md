# run.sh

Runs Photosphere's smoke test scenarios for one platform. Invoked by the root `package.json` scripts `test:ziggy`, `test:ziggy:and` and `test:ziggy:ios`, never directly.

## Arguments

- `<platform>`: `linux`, `windows`, `macos`, `android` or `ios`. Each has a platform library in `lib/<platform>.sh` that puts the app in place, starts it and stops it. On iOS that is a connected iPhone or iPad when there is one (see `lib/ios-device.sh`), otherwise a simulator.
- `[scenario]`: optional scenario number or full directory name, to run one scenario, as in `bun run test:ziggy:and -- 40`. `PHOTOSPHERE_SMOKE_SCENARIO=<number or name>` does the same. A run of one scenario does not record the what-changed baseline; a full run that passes does.

## Behaviour

Installs the app for the platform once, from a build: the directory `PHOTOSPHERE_SMOKE_BUILD` names, which the platform's build script in `apps/photosphere/scripts` has already built the app into (what CI's `app-build` job makes), else one the platform library builds into `<run directory>/build` with that same script. The runner never installs a package. The build directory is laid out as the build script writes it:

- Linux: `<build>/bin/photosphere`, from `build:linux -- --prefix <build>`.
- Windows: `<build>/photosphere/photosphere.exe`, from `build:windows -- --prefix <build>`. Give the path in a form both Git Bash and native Windows programs accept (`cygpath -m`).
- MacOS: `<build>/xcode/Build/Products/Release/Photosphere.app`, from `build:macos -- --configuration Release --native-dir <build>/native --build-dir <build>/xcode`.
- iOS simulator: `<build>/xcode/Build/Products/Release-iphonesimulator/Photosphere.app`, from `build:ios -- --sdk simulator --configuration Release --native-dir <build>/native --build-dir <build>/xcode`. A connected device is built for by `lib/ios-device.sh` itself.
- Android: `<build>/photosphere.apk`, from `build:android -- --output-dir <build>`. This is a debug-type APK of the release library, which the scenarios need because they seed and read the app's data through `run-as`. When the library builds it, it builds for the architectures of the attached devices.

The runner also builds the Zig `psi` CLI into the run directory, which scenarios run on this host through `run_zig_cli` as the other side of a LAN share. Then runs each scenario's `test.sh` through the rolling test pool in `scripts/lib/test-pool.sh`, giving each its own temporary directory (`PHOTOSPHERE_TMP_DIR`) and a held-to timeout and a log of its own, which is printed together once the scenario finishes. A scenario that exits with 77 is skipped. On every platform the pool is as wide as `resolve_test_parallel` in `scripts/lib/test-concurrency.sh` says (`PHOTOSPHERE_TEST_PARALLEL` overrides it), as the other suites are. A platform whose scenarios each need a device caps it at the devices it has: on Android the devices that can reach the host (the devices named in `PHOTOSPHERE_ANDROID_DEVICES`, else the pool emulators on the LAN bridge, else a plugged-in device, else any other emulator such as the single one `bun run emu:and:up` starts), and on iOS the one simulator. A scenario claims one device under the per-device lock the mobile suite and the pool repair share, and skips a device that is not responding or is off the LAN bridge, so two scenarios never share a device. It ends by printing how many scenarios passed, were skipped and failed, with the names of those that failed, and exits non-zero when any failed or when none passed. Each app instance a scenario starts has a [remote control server](https://github.com/ashleydavis/ziggy/blob/main/tools/remote-control-server/README.md) of its own, started by the platform's `photosphere_platform_start`. The app is started with `--remote-control` (the `ziggy.remoteControl` extra on Android) and connects out to the server. The scenario drives the app through the server's script port; see `lib/common.sh` for what a scenario can do and what a platform library implements. Every process started is recorded as it is launched, and any still running at the end fails the run and is stopped.

Every scenario is offered to every platform. One that cannot run on a platform exits with the skipped code itself, as the MCP server and menu scenarios do on a phone and the automatic import permission scenarios do on a desktop.
