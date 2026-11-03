# app-log.sh

Prints the Photosphere App's log file from the device or computer the app runs on: the main log, or with `--errors` the errors log. It reads the newest file in the app's log folder, so it always shows the run that started last.

Invoke: `bun run app:log -- --platform <linux|macos|windows|android|ios> [--target <t>] [--errors] [--from-line <n>] [--path]` from the repository root, or `bun run --filter=ziggy app:log -- ...`. Run with no arguments, it prints its usage and exits 2.

- `--platform <p>`: where the app runs: `linux`, `macos`, `windows`, `android` or `ios`.
- `--target <t>`: the adb serial of the Android device, or the udid of the iOS simulator. Without it, the script uses the only Android device `adb devices` lists, or the only booted simulator, and fails with a list of them when there is none or more than one.
- `--errors`: read the errors log (`photosphere-<start time>-errors.log`) instead of the main log (`photosphere-<start time>.log`).
- `--from-line <n>`: print the file from line `n` onward, where `n` is a positive whole number. Without it, the whole file is printed.
- `--path`: print the chosen file's path and nothing else. A new path means the app has restarted and started a new log file.

The log folder is the `logs` folder of the app's data directory:

- `linux`: `${XDG_DATA_HOME:-$HOME/.local/share}/au.com.codecapers.photosphere/logs`.
- `macos`: `$HOME/Library/Application Support/au.com.codecapers.photosphere/logs`.
- `windows`: `$LOCALAPPDATA/au.com.codecapers.photosphere/logs`. The script fails when `LOCALAPPDATA` is not set.
- `android`: `files/logs` in the sandbox of `au.com.codecapers.photosphere.ziggy`, read through `adb exec-out run-as`.
- `ios`: `Library/Application Support/au.com.codecapers.photosphere.ziggy/logs` in the app's data container on the simulator (`xcrun simctl get_app_container <udid> au.com.codecapers.photosphere.ziggy data`). The script reads only from the iOS simulator and refuses a physical device.

`PHOTOSPHERE_LOG_DIR` moves the log folder to `$PHOTOSPHERE_LOG_DIR/logs` on every platform, the same way it moves it for the app (on Android, as an absolute path on the device). The story player and the Android smoke tests set it. On Linux, `XDG_DATA_HOME` moves the data directory, and on Windows `LOCALAPPDATA` does. Set the same value the app was started with.

The script takes no Android device lock, so it can read the log of a pool emulator a test is using.
