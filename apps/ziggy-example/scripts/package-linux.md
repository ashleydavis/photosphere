# package-linux.sh

Builds the example for release, without the test hooks, and packages it as `out/linux/ziggy-example-<version>-linux-<arch>.zip` and `.deb`. The version comes from `apps/ziggy-example/package.json`. The packages are unsigned. Runs on Linux and needs `zip` and `dpkg-deb`.

The zip holds one folder with the executable and its page. The deb installs them under `/opt/ziggy-example`, links the executable into `/usr/bin`, and depends on the GTK 3 and WebKitGTK 4.1 runtime libraries (`libgtk-3-0` and `libwebkit2gtk-4.1-0`).

No arguments.
