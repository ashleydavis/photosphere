# run.sh

Runs the Ziggy smoke test scenarios for one platform. Invoked by the root `package.json` scripts `test:ziggy`, `test:ziggy:and` and `test:ziggy:ios`, never directly.

## Arguments

- `<platform>`: `desktop`, `android` or `ios`. `desktop` runs on the host operating system.
- `[scenario]`: optional scenario number or name to run one scenario.

## Behaviour

Builds the app for the platform, then runs each scenario's `test.sh` through the shared runner and pool libraries, giving each its own temporary directory. Exit code 77 from a scenario is a skip. Every process started is recorded when it is started and killed through `kill_process_tree` at the end.
