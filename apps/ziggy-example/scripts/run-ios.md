# run-ios

Builds the app and runs it: on a connected iPhone or iPad when there is one, otherwise on an existing simulator (booting it if needed, with its output in the terminal), otherwise it fails with an error. It never creates or deletes a simulator.

Run it with `bun run run:ziggy-example:ios`, on a Mac.

A device build is signed by the development team of the account signed in to Xcode (Preferences, Accounts), installed with `ios-device.ts` through native-run's device library (the one Capacitor uses), and launched paused under the device's debugserver, which lldb then detaches from so the app runs on by itself. native-run supports devices up to iOS 16. The first time, iOS may refuse to open the app until the developer is trusted under Settings, General, VPN & Device Management.

## Environment

- `ZIGGY_IOS_DEVICE`: the identifier of the device to use. Without it, the first connected device is used. List them with `node_modules/.bin/native-run ios --list`.
- `ZIGGY_IOS_TEAM`: the development team to sign with. Needed only when Xcode has more than one.
- `ZIGGY_IOS_SIMULATOR`: the name or identifier of the simulator to use when no device is connected. Without it, a simulator that is already running is used, otherwise the first available iPhone.
