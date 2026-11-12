# Test workflow timings

How long each test workflow takes, and what each change to one did to that, measured on GitHub Actions from the runs of the commit named. Every time is wall clock for that workflow, from the run's start to its finish, with the slowest job beside it.

## Baseline

Commit `101f73c72`, every workflow green. The test workflows are the release workflows with packaging and publishing taken out, so this is what a plain test run costs.

| Workflow | Total | Slowest job |
|---|---|---|
| Test macOS arm64 | 20m 15s | app-smoke-tests 10m 09s |
| Test Windows | 24m 32s | app-smoke-tests 14m 50s |
| Test macOS x64 | 25m 58s | app-smoke-tests 14m 25s |
| Test Android | 28m 38s | app-smoke-tests 20m 15s |
| Test iOS | 32m 42s | app-smoke-tests 18m 21s |
| Test Linux | 34m 30s | app-smoke-tests 28m 48s |

Build times, in seconds:

| Job | Linux | Windows | macOS arm64 | macOS x64 | Android | iOS |
|---|---|---|---|---|---|---|
| app-build | 277 | 397 | 398 | 542 | 364 | 596 |
| cli-build | 139 | 251 | 210 | 263 | n/a | n/a |
| zig-unit-tests | 203 | 783 | 299 | 668 | 480 | 286 |
