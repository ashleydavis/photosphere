# common.sh

The shared helpers of Photosphere's smoke tests. Every scenario's `test.sh` sources it, and it is never run on its own:

```bash
source "$TEST_DIR/../lib/common.sh"
```

It takes no arguments. It sources `scripts/lib/test-lib.sh` and `scripts/lib/process-control.sh`, then the platform library `lib/<platform>.sh` for the platform in `PHOTOSPHERE_SMOKE_PLATFORM`.

It gives a scenario what it needs to start the app in test mode, drive it through the test control connection (see "Test hooks" in [Ziggy architecture](../../../packages/ziggy/docs/architecture.md)) and check what it logs and what the page shows: `start_app`, `wait_for_ready`, `send_command`, `read_value` and the `wait_for_*` helpers, `check_no_errors`, `stop_app`, the vault and config helpers, the S3 emulator helpers, and `run_cli` for the `psi` CLI. Each helper has a comment with its usage above it.

The comment at the top of the file lists what a platform library must implement: `photosphere_platform_prepare`, `photosphere_platform_start`, `photosphere_platform_stop`, `photosphere_platform_wait_exit`, `photosphere_platform_is_running`, `photosphere_platform_reset_app_state`, and optionally `photosphere_platform_screenshot`.

## Environment

- `PHOTOSPHERE_SMOKE_PLATFORM`: `linux`, `windows`, `macos`, `android` or `ios`. The runner sets it. A scenario run by hand on a desktop gets the host's.
- `PHOTOSPHERE_SMOKE_RUN_DIR`: the run directory holding the build the runner made. A scenario run by hand names it.
- `PHOTOSPHERE_TMP_DIR`: the scenario's own temporary directory, given by the runner.
- `PHOTOSPHERE_SMOKE_DIR` and `PHOTOSPHERE_SMOKE_REPO_ROOT`: the smoke test directory and the repository root, worked out from where the file is when they are not set.
