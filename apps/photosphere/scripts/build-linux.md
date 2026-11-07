# build-linux.sh

Runs `sync-linux.sh`, which produces Photosphere's Linux executable, with its page embedded, in `native/linux/zig-out/bin`, or in `<prefix>/bin` when given `--prefix <dir>`. Runs on Linux. Passes its arguments on, so it takes the options `sync-linux.md` lists.
