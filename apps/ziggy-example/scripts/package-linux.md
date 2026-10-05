# package-linux.sh

Builds the example for release, without the test hooks, and packages it as `out/linux/ziggy-example-<version>-linux-<arch>.zip` and `.deb`. The version comes from `apps/ziggy-example/package.json`. The packages are unsigned. Runs on Linux and needs `zip` and `dpkg-deb`.

The page is embedded in the executable, so the app is one file. The zip holds one folder with that executable. The deb installs it as `/opt/ziggy-example/ziggy-example`, links it into `/usr/bin`, and depends on the GTK 3 and WebKitGTK 4.1 runtime libraries (`libgtk-3-0` and `libwebkit2gtk-4.1-0`).

No arguments.
