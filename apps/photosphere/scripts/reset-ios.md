# reset-ios.sh

Wipes everything Photosphere has stored on an iOS simulator, so the next `bun run ios` starts from a fresh install: it uninstalls the app, which removes its container (Documents, Library and the web view's storage), and resets the simulator's photo permission and keychain, which the simulator keeps outside the container. The simulator's photo library is not touched.

It works on a simulator only. Everything it does goes through `xcrun simctl`, which reaches simulators only, and it refuses to run while a real device is connected, because `bun run ios` would then run on that device rather than on the simulator it wiped.

Invoke: `bun run ios:reset` from the repository root, on a Mac. It takes no arguments.

## Environment

- `PHOTOSPHERE_IOS_SIMULATOR`: the name or identifier of the simulator to wipe. Without it the simulator is picked the way [run-ios](run-ios.md) picks one: one that is already running, otherwise the first available iPhone.
- `PHOTOSPHERE_IOS_DEVICE`: when set, names a device, so the script refuses to run, as `bun run ios` would use that device.
