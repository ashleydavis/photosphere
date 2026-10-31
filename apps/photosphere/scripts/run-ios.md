# run-ios

Builds the app and runs it: on a connected iPhone or iPad when there is one, otherwise on an existing simulator (booting it if needed, with its output in the terminal), otherwise it fails with an error. It never creates or deletes a simulator.

Run it with `bun run ios`, on a Mac. `bun run ios:50`, `ios:1` and `ios:0` also put a test database on the simulator, as `bun run android:50` does on Android.

- `[fixture]`: a test database to put on the simulator: `50`, `1` or `0` for `50-assets`, `1-asset` and `no-assets`, or the name of any directory under `test/dbs`. It is copied into the app's storage directory (`Library/Application Support/au.com.codecapers.photosphere.ziggy` in its data container), registered in the app's `databases.toml` (`.config/photosphere` in the container) as `test-<name>` by `write-fixture-databases-config.ts`, and made the database the app opens on launch. A simulator only: with a device connected it fails.

A device build is signed by the development team of the account signed in to Xcode (Preferences, Accounts), installed with `ios-device.ts` through native-run's device library, and launched paused under the device's debugserver, which lldb then detaches from so the app runs on by itself. native-run supports devices up to iOS 16. The first time, iOS may refuse to open the app until the developer is trusted under Settings, General, VPN & Device Management.

## Environment

- `PHOTOSPHERE_IOS_DEVICE`: the identifier of the device to use. Without it, the first connected device is used. List them with `node_modules/.bin/native-run ios --list`.
- `PHOTOSPHERE_IOS_TEAM`: the development team to sign with. Needed only when Xcode has more than one.
- `PHOTOSPHERE_IOS_SIMULATOR`: the name or identifier of the simulator to use when no device is connected. Without it, a simulator that is already running is used, otherwise the first available iPhone.
