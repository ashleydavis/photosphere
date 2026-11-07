# ios-device

Drives a connected iOS device for `run-ios.sh`. Xcode 14 has no command for running an app on a device, so it uses native-run's device library. It runs under Node (pinned in `mise.toml`), because Bun's sockets cannot carry the TLS session native-run starts on a device service.

## Usage

- `node scripts/ios-device.ts install <udid> <bundle-id> <app-path>`: copies the signed `.app` to the device and installs it, replacing any installed copy.
- `node scripts/ios-device.ts launch <udid> <bundle-id> <info-file> [NAME=VALUE...] [-- ARGUMENT...]`: launches the installed app under the device's debugserver with the given environment and the command-line arguments after `--`, stopped at its first instruction, then passes one connection on a free loopback port through to that debugserver. Writes `{"port", "container"}` to `<info-file>` once it is listening. lldb takes the process over with `process connect connect://127.0.0.1:<port>`.
- `node scripts/ios-device.ts forward <udid> <device-port> <info-file>`: passes each connection on a free loopback port through to `<device-port>` on the device over USB, as `adb forward` does for Android. Writes `{"port"}` to `<info-file>` once it is listening, and runs until it is stopped.

## Arguments

- `<udid>`: the device's identifier, as `node_modules/.bin/native-run ios --list` prints it.
- `<bundle-id>`: the app's bundle identifier, `au.com.codecapers.photosphere.ziggy`.
- `<app-path>`: the `.app` built for a device by `build-ios.sh --sdk device`.
- `<info-file>`: where the JSON describing the listening port is written.
- `NAME=VALUE`: an environment variable for the app.
- `ARGUMENT`: a command-line argument for the app, such as `--remote-control <host:port>`.
- `<device-port>`: a TCP port the app listens on, on the device's loopback.
