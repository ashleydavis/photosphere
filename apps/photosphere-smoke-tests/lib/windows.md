# windows.sh

The Windows platform library of Photosphere's smoke tests. [common.sh](common.md) sources it when the platform is `windows`, and it is never run on its own. It takes no arguments. Run the suite under Git Bash on Windows.

It implements the `photosphere_platform_*` functions `common.sh` lists, and `windows_native_path`, which prints a path in the form a native Windows program understands. The app opens a normal window on the session's desktop, so no virtual display is needed. Each scenario points `LOCALAPPDATA` at its own directory, which is where WebView2 keeps its profile, so two scenarios never share one, and the settings, vault and logs are in the scenario's directory through the same `PHOTOSPHERE_*` variables the Linux library sets.

`PHOTOSPHERE_NEWS_URL` is passed on to the app, for the scenarios that serve a news feed.

The helpers a scenario calls as `windows_<name>` (seeding databases and settings, the photo library, the background log and the rest) are the Linux library's: `windows.sh` reads [linux.sh](linux.md) first, defines its own `photosphere_platform_*` functions in place of Linux's, and gives every `linux_<name>` helper a `windows_<name>` name. Those helpers work on the scenario's own directory with the tools Git Bash has, and the paths they write are in the native form, because the scenario directory is.

Stopping the app ends its Windows process and its whole tree (`taskkill /T /F`) by the Windows pid recorded in `app.winpid` when it started, then waits for it to be gone. Signalling the shell's process group alone leaves the Windows process running for many seconds, still working on the scenario's data, and its WebView2 processes holding the user data folder. Starting the app waits until the scenario's own WebView2 user data folder is free, which it reads from the folder's lockfile, never from the WebView2 processes of the whole machine.
