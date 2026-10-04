# run-ios

Builds the app for the simulator, installs it on an existing simulator (booting it if needed) and launches it with its output in the terminal. It never creates or deletes a simulator.

Run it on a Mac: `mise exec -- bash apps/ziggy-example/scripts/run-ios.sh`. List the simulators with `xcrun simctl list devices available`.

## Environment

- `ZIGGY_IOS_SIMULATOR`: the name or identifier of the simulator to use. Without it, a simulator that is already running is used, otherwise the first available iPhone.
