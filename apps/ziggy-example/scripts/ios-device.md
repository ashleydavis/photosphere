# ios-device

Drives a connected iOS device for `run-ios.sh` and for the Ziggy example's iOS smoke tests when a device is connected (`bun run test:ziggy-example:ios`, platform library `smoke-tests/lib/ios-device.sh`). Xcode 14 has no command for running an app on a device, so it uses native-run's device library, the one Capacitor's `cap run ios` deploys with. It runs under Node (pinned in `mise.toml`), because Bun's sockets cannot carry the TLS session native-run starts on a device service.

## Usage

- `node scripts/ios-device.ts install <udid> <bundle-id> <app-path>`: copies the signed `.app` to the device and installs it, replacing any installed copy.
- `node scripts/ios-device.ts launch <udid> <bundle-id> <info-file> [NAME=VALUE...]`: launches the installed app under the device's debugserver with the given environment, stopped at its first instruction, then passes one connection on a free loopback port through to that debugserver. Writes `{"port", "container"}` to `<info-file>` once it is listening. lldb takes the process over with `process connect connect://127.0.0.1:<port>`.
- `node scripts/ios-device.ts forward <udid> <device-port> <info-file>`: passes each connection on a free loopback port through to `<device-port>` on the device over USB, as `adb forward` does for Android. Writes `{"port"}` to `<info-file>` once it is listening, and runs until it is stopped.

## Arguments

- `<udid>`: the device's identifier, as `node_modules/.bin/native-run ios --list` prints it.
- `<bundle-id>`: the app's bundle identifier, `dev.ziggy.example`.
- `<app-path>`: the `.app` built for a device by `build-ios.sh --sdk device`.
- `<info-file>`: where the JSON describing the listening port is written.
- `NAME=VALUE`: an environment variable for the app.
- `<device-port>`: a TCP port the app listens on, on the device's loopback.
