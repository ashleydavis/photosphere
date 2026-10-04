# package-linux.sh

Builds the Linux shell (`build-linux.sh`) and packages it for distribution. Invoked as `bun run --filter=ziggy package:linux`.

Produces a `deb` with `dpkg-deb` and a `zip`, unsigned, in the Linux output folder, named `photosphere-<version>-linux-<arch>.<ext>`. Takes no arguments. Runs on Linux.
