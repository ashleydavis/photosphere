# Commander fixtures

Golden fixtures that check the Zig port of `commander` (`apps/cli-zig/src/lib/commander.zig`). They were written by commander.js and by the TypeScript implementation of `psi`, and are now the reference the Zig port is held to. Change them only together with the behaviour they describe.

- `programs.json`: programs described as data (options, arguments, aliases, subcommands, help text, hooks, actions, option parsers, output width and colors). For every command line of a program it records what commander.js wrote to stdout and stderr, the `CommanderError` or `process.exit` it ended with, and the hooks, actions and option parsers that ran with what they were given. `src/test/commander.test.zig` builds the same programs from the same definitions with the Zig port and expects the same results.
- `psi.json`: command lines of `psi replicate` and `psi verify` with the stdout, stderr and exit code the TypeScript implementation produced with `NO_COLOR=1`.
