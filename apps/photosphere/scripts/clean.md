# clean.sh

Removes the build output of every platform. Invoked as `bun run --filter=ziggy clean`. Takes no arguments. Runs on any platform.

Uses each build tool's own clean command (Gradle, `xcodebuild`, Zig's cache and install directories by name), or removes a single named file at a time. It never deletes recursively.
