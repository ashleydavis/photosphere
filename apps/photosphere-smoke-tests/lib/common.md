# common.sh

The shared helpers of Photosphere's smoke tests. Every scenario's `test.sh` sources it, and it is never run on its own:

```bash
source "$TEST_DIR/../lib/common.sh"
```

It takes no arguments. It sources `scripts/lib/test-lib.sh` and `scripts/lib/process-control.sh`, then the platform library `lib/<platform>.sh` for the platform in `PHOTOSPHERE_SMOKE_PLATFORM`.

It gives a scenario what it needs to start the app in test mode, drive it through the remote control server (see "Remote control" in [Ziggy architecture](https://github.com/ashleydavis/ziggy/blob/main/docs/development/architecture.md#remote-control)) and check what it logs and what the page shows: `start_app`, `wait_for_ready`, `send_command`, `read_value` and the `wait_for_*` helpers, `check_no_errors`, `stop_app`, the vault and config helpers, the S3 emulator helpers, and `run_cli` for the `psi` CLI. Each helper has a comment with its usage above it.

Each app instance of a scenario has a [remote control server](https://github.com/ashleydavis/ziggy/blob/main/tools/remote-control-server/README.md) of its own. `photosphere_start_remote_control_server` starts it on ports the system chooses and reads the ports from the line it prints when it listens. Each platform's `photosphere_platform_start` calls it, then starts the app with `--remote-control` and the server's app port (the `ziggy.remoteControl` extra on Android). The app connects out to the server. The scenario talks to the server's script port. `PHOTOSPHERE_TEST_MODE=1` is Photosphere's own test mode. The platform libraries set it beside `--remote-control`.

The comment at the top of the file lists what a platform library must implement: `photosphere_platform_prepare`, `photosphere_platform_start`, `photosphere_platform_stop`, `photosphere_platform_wait_exit`, `photosphere_platform_is_running`, `photosphere_platform_reset_app_state`, and optionally `photosphere_platform_screenshot`.

## Environment

- `PHOTOSPHERE_SMOKE_PLATFORM`: `linux`, `windows`, `macos`, `android` or `ios`. The runner sets it. A scenario run by hand on a desktop gets the host's.
- `PHOTOSPHERE_SMOKE_RUN_DIR`: the run directory holding the build the runner made. A scenario run by hand names it.
- `PHOTOSPHERE_TMP_DIR`: the scenario's own temporary directory, given by the runner.
- `PHOTOSPHERE_SMOKE_BUILD`: a directory the platform's build script has already built the app into, which `photosphere_platform_prepare` takes the app from in place of building it. [run.md](../run.md) gives the layout per platform.
- `PHOTOSPHERE_CONTROL_HOST` and `PHOTOSPHERE_CONTROL_PORT`: where the scenario connects, the server's script port. `photosphere_start_remote_control_server` sets them.
- `PHOTOSPHERE_REMOTE_CONTROL`: the address the app is started with, `host:port` of the server's app port. `photosphere_start_remote_control_server` sets it.
- `PHOTOSPHERE_SMOKE_DIR` and `PHOTOSPHERE_SMOKE_REPO_ROOT`: the smoke test directory and the repository root, worked out from where the file is when they are not set.
