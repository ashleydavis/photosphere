# windows.sh

The Windows platform library of Photosphere's smoke tests. [common.sh](common.md) sources it when the platform is `windows`, and it is never run on its own. It takes no arguments. Run the suite under Git Bash on Windows.

It implements the `photosphere_platform_*` functions `common.sh` lists, and `windows_native_path`, which prints a path in the form a native Windows program understands. The app opens a normal window on the session's desktop, so no virtual display is needed. Each scenario points `LOCALAPPDATA` at its own directory, which is where WebView2 keeps its profile, so two scenarios never share one, and the settings, vault and logs are in the scenario's directory through the same `PHOTOSPHERE_*` variables the Linux library sets.

`PHOTOSPHERE_NEWS_URL` is passed on to the app, for the scenarios that serve a news feed.
