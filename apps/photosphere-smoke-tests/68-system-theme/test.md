# 68-system-theme

Proves that with the setting `system`, the app's theme is the operating system's theme: the page is light when the system is light and
dark when it is dark. It reads the system's theme on Linux with `gsettings`, on macOS with `defaults read -g AppleInterfaceStyle` and
on Windows with the `AppsUseLightTheme` registry value, and checks the screenshot's mean brightness against it.

`run.sh` runs it on a desktop platform. To run it alone:

```
PHOTOSPHERE_SMOKE_SCENARIO=68-system-theme bun run test:ziggy
```
