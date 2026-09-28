# xdg-open (opener stand-in)

Stands in for the Linux URL opener while `smoke-tests-zig/96-bug` runs, so `psi bug` starts no browser.

The test puts this directory first on the `PATH` of each `psi bug` it runs. `psi bug` (the TypeScript CLI through the
`open` package, and the Zig port) then runs this script as `xdg-open <url>`.

Arguments:

- `<url>`: the GitHub issue URL `psi bug` built.

Environment:

- `BUG_OPENER_CAPTURE_FILE`: the file the URL is written to. It is written under `<file>.partial` first and renamed
  into place, so the test never reads half of it. The script fails when the variable is not set.

`open` beside it is the same stand-in under the macOS opener's name.
