# story-player.sh

Plays the running app through every registered UI story, in light and then dark, and captures a screenshot of each. It is the command-line version of the "Play on automatic" button in the stories browser. The root `package.json` scripts call it: `stories`, `stories:and` and `stories:ios` for the deprecated Electron and Capacitor apps, and `stories:ziggy`, `stories:ziggy:and` and `stories:ziggy:ios` for the Photosphere App. Run those rather than the script. For the stories themselves see `packages/user-interface/src/stories/README.md`.

## Arguments

- `--platform <name>`: where the stories play. `electron` (the default), `android`, `ios`, `ziggy` (the Photosphere App on this operating system), `ziggy-android` (the Photosphere App on an Android emulator from the pool, or an attached device) or `ziggy-ios` (the Photosphere App on the iOS simulator).
- `--duration <ms>`: how long a story is shown before the cycle moves on by itself. The player moves the cycle on as soon as the screenshot is written, so this only matters when a capture dies.
- `--screenshots <dir>`: where the PNGs go. The default is `stories-screenshots/<platform>`.
- `--no-screenshots`: play the stories without capturing anything.
- `--open`: open the generated `index.html` when the run finishes.
- `--headless`: hide the window. It applies to Electron and to the Photosphere App on Linux, which then runs on a virtual display. A phone or simulator window is always shown.

## What it does

Builds the app in test mode, starts it, navigates it to the stories cycle and waits for `STORIES CYCLE COMPLETE` in the app's log. Each time the app logs `STORIES CYCLE READY`, the player takes a screenshot and tells the cycle to advance. A `STORIES CYCLE FAILED` line, or a run that captured no screenshot, fails the run.

The Photosphere App platforms are driven through the app's test control connection (see "Test hooks" in `packages/ziggy/docs/architecture.md`), with the commands `ready`, `navigate`, `screenshot`, `cycle-advance` and `quit`. They use the platform libraries of `apps/photosphere-smoke-tests`, so the app is built and started the way the smoke tests do it. The app on a desktop writes the screenshot itself. On Android and the iOS simulator the screenshot is taken from the host with `adb` or `simctl`, so it is of the whole screen. The Electron and Capacitor platforms are driven over HTTP by their own harnesses.

The app runs with the repository as its working directory, because the stories that show real photos open the relative path `test/dbs/50-assets`. On a phone that fixture is copied into the app's storage first, and the app's data is cleared again when the run ends.
