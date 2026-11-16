# 69-system-theme-change

Proves that with the setting `system`, a change of the system's appearance reaches the page while the app runs: the page follows the
new theme and then the restored one. It changes the system's appearance, which on a desktop is the developer's own screen, so it runs
only in the workflow and is never part of an unfiltered local run.

To run it locally, name it:

```
PHOTOSPHERE_SMOKE_SCENARIO=69-system-theme-change bun run test:ziggy
```

It changes the desktop's appearance while it runs and puts the value it found back at the end. On Linux the app hears of the change
only through the desktop portal's Settings interface on the session bus, so the Release Linux workflow installs `xdg-desktop-portal`
with its GNOME backend and runs the smoke tests under `dbus-run-session`. On a connected iPhone or iPad it exits
with the skipped code, because no host command changes the device's appearance.
