# macos.sh

The MacOS platform library of Photosphere's smoke tests. [common.sh](common.md) sources it when the platform is `macos`, and it is never run on its own. It takes no arguments.

It implements the `photosphere_platform_*` functions `common.sh` lists. The app is the built `Photosphere.app`'s executable, started directly so its process group is known. Each scenario gets a home directory of its own (`HOME` and `CFFIXED_USER_HOME`), so the web view's data and the app's Application Support directory are isolated, and the settings, vault and logs are in the scenario's directory through the same `PHOTOSPHERE_*` variables the Linux library sets. The app opens a real window, so the run needs a logged-in graphical session.

The app is started under `caffeinate -d -u`, which turns the display on if it is off and keeps it awake until the app ends. A sleeping display occludes the window, WebKit then marks the page hidden and stops running animation frames, and the gallery, whose width arrives in one, never renders a thumb.

`PHOTOSPHERE_NEWS_URL` is passed on to the app, for the scenarios that serve a news feed.
