# write-fixture-databases-config.ts

Writes the app's `databases.toml` with one test database registered, merged into the file a device already had, and the `databases` section of its `state.yaml` with that database made the most recent and the one the app reopens on launch, merged into the `state.yaml` the device already had. `run-android.sh` and `run-ios.sh` use it when given a fixture: they read the existing files off the device, run this, and put the results back into the app's storage.

The fixture is named `test-<name>`, so the app starts in it. Every other `test-` entry and `test-` recent is removed first, so fixtures do not pile up from run to run. The user's own entries, their recents and every other section of `state.yaml` are kept as they were. A file that does not parse, or does not hold a mapping, stops it with an error rather than being replaced.

Invoke: `bun scripts/write-fixture-databases-config.ts <name> <path> <existing-databases> <databases-output> <existing-state> <state-output>` from `apps/photosphere`.

- `<name>`: the fixture's name, such as `50-assets`. The entry is named `test-<name>`.
- `<path>`: the full path of the database on the device. The app opens it by this path.
- `<existing-databases>`: the `databases.toml` the device had. Empty when it had none.
- `<databases-output>`: where the merged `databases.toml` is written.
- `<existing-state>`: the `state.yaml` the device had. Empty when it had none.
- `<state-output>`: where the merged `state.yaml` is written.
