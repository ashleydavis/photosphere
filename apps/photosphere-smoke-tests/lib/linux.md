# linux.sh

The Linux platform library of Photosphere's smoke tests. [common.sh](common.md) sources it when the platform is `linux`, and it is never run on its own. It takes no arguments.

It implements the `photosphere_platform_*` functions `common.sh` lists, and the `linux_*` helpers scenarios call as `${PLATFORM}_<name>`.

The app runs on a virtual display of its own, so a run shows no window and two runs never share a display. WebKitGTK's bubblewrap sandbox is switched off for these test processes only, through the environment WebKitGTK documents for it, because some Linux setups do not let an unprivileged program create it. The app is started in test mode with its settings, vault, cache and logs inside the scenario's directory, and the control connection's port is read from the file the core writes.

## Environment

- `SHOW_UI=1`: show the window instead of using a virtual display, for watching a failing scenario.
- `PHOTOSPHERE_NEWS_URL`: passed on to the app, for the scenarios that serve a news feed.
