# set-sync-interval-android.sh

Switches syncing on in the Photosphere App on an Android device or emulator and sets how long it waits between sync passes, so a manual test that waits on a sync does not wait the default 5 minutes. It writes the `sync` section of the app's `config.yaml`, keeping every other section, and checks the file afterwards. It stops the app first, because the app writes its settings when it closes and would put the old ones back.

Invoke: `bun run android:set-sync-interval -- [--target <adb serial>] <seconds>` from the repository root.

- `<seconds>`: the time between sync passes, a whole number greater than 0, such as `10`.
- `--target <serial>`: the device to use (or set `PHOTOSPHERE_ANDROID_TARGET`). Without it the device is picked the way [run-android](run-android.md) picks one.

The app must be installed. Run it after `bun run android:reset` and before the command that starts the app, such as `bun run android:50`. It only works on a build the device lets `run-as` reach, which the debug build `bun run android` installs is.
