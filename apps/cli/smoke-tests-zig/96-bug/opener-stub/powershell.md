# powershell.zig (opener stand-in)

Stands in for Windows PowerShell, the Windows URL opener, while `smoke-tests-zig/96-bug` runs, so `psi bug` starts no
browser.

On Windows `psi bug` (the TypeScript CLI through the `open` package, and the Zig port) runs
`%SYSTEMROOT%\System32\WindowsPowerShell\v1.0\powershell.exe`, not a program found on the `PATH`. The test builds this
file at test time with `zig build-exe` as that `powershell.exe` under a directory in its per-test temp dir, and runs each
`psi bug` with `SYSTEMROOT` pointing at that directory. No binary is checked in.

Arguments:

- Whatever `psi bug` passes PowerShell: `-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand <command>`,
  where `<command>` is `Start "<url>"` encoded as base64 UTF-16LE. The stand-in records them without interpreting them;
  the test checks them and decodes the URL.

Environment:

- `BUG_OPENER_CAPTURE_FILE`: the file the arguments are written to, one per line. It is written under `<file>.partial`
  first and renamed into place, so the test never reads half of it. The stand-in fails when the variable is not set.

`open` and `xdg-open` beside it are the stand-ins for macOS and Linux.
