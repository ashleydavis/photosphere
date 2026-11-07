# 139: special characters in file names

Checks that a JPEG, a PNG and an MP4 whose names hold a space, `$`, a backtick and, except on Windows, a `"` are added to a database, each with a JPEG thumbnail. `"` is a reserved character in Windows file names, so it is left out there.

The test copies the three files into a photos directory, and adds the directory with `psi add --verbose`. It checks that three files are added and none fail, that each asset id in the output has a thumbnail that is a JPEG, that the summary counts three files and that the database verifies.

## Running it

```
bun run test:cli:zig -- 139
```

It takes no arguments.
