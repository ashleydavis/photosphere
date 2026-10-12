# write-fixture-databases-config.ts

Writes the app's `databases.toml` with one test database registered, merged into the file a device already had. `run-android.sh` uses it when given a fixture: it reads the existing file off the device, runs this, and pushes the result back into the app's storage.

The fixture is named `test-<name>`, made the most recent database and made the one the app reopens on launch, so the app starts in it. Every other `test-` entry is removed first, so fixtures do not pile up from run to run. The user's own entries and recents are left as they were. Malformed TOML stops it with an error rather than being replaced.

Invoke: `bun scripts/write-fixture-databases-config.ts <name> <path> <existing-file> <output-file>` from `apps/photosphere`.

- `<name>`: the fixture's name, such as `50-assets`. The entry is named `test-<name>`.
- `<path>`: the full path of the database on the device. The app opens it by this path.
- `<existing-file>`: the `databases.toml` the device had. Empty when it had none.
- `<output-file>`: where the merged `databases.toml` is written.
