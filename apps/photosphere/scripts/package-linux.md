# package-linux.sh

Builds Photosphere for release, without the test hooks, and packages it as `out/linux/photosphere-<version>-linux-<arch>.zip` and `.deb`. The version comes from `--version`, or from `apps/photosphere/package.json` when it is not given. The packages are unsigned. Runs on Linux and needs `zip` and `dpkg-deb`.

The page is embedded in the executable, so the app is one file. The zip holds one folder with that executable. The deb installs it as `/opt/photosphere/photosphere`, links it into `/usr/bin`, adds a menu entry (`/usr/share/applications/au.com.codecapers.photosphere.desktop`) so the app shows in the applications menu and search, installs the 512 pixel icon (`apps/photosphere/icons/photosphere-512.png`) in the hicolor theme for it, and depends on the GTK 3 and WebKitGTK 4.1 runtime libraries (`libgtk-3-0`, `libgdk-pixbuf-2.0-0` and `libwebkit2gtk-4.1-0`) and on the GStreamer plugins WebKitGTK plays video with (`gstreamer1.0-plugins-good` and `gstreamer1.0-libav`).

## Arguments

- `--version <version>`: the version in the file names, such as `1.2.3` for the tag `v1.2.3` or `dev-nightly.20260101` for a nightly. Default: the version in `apps/photosphere/package.json`. A version that does not start with a digit is written into the deb as `0.0.0~<version>`, because Debian requires a leading digit.
