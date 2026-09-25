# generate.ts

Generates the golden fixtures that check the Zig port of `commander` (`apps/cli-zig/src/lib/commander.zig`)
against commander.js, the version the psi CLI resolves.

## Invocation

From the repo root:

```
bun run apps/cli-zig/src/test/fixtures/commander/generate.ts
```

It takes no arguments. Run it again after changing the program definitions or the command lines in it, after
upgrading commander, or after changing the replicate or verify command definitions in `apps/cli/index.ts`, and
check in the regenerated JSON.

## What it writes

- `programs.json`: programs described as data (options, arguments, aliases, subcommands, help text, hooks,
  actions, option parsers, output width and colors). For every command line of a program it records what
  commander.js wrote to stdout and stderr, the `CommanderError` or `process.exit` it ended with, and the hooks,
  actions and option parsers that ran with what they were given. `src/test/commander.test.zig` builds the same
  programs from the same definitions with the Zig port and expects the same results.
- `psi.json`: command lines of `psi replicate` and `psi verify` run through the real TypeScript CLI
  (`apps/cli/index.ts`, with `NO_COLOR=1`), with their stdout, stderr and exit code.
  `src/test/main.test.zig` runs the built Zig `psi` with the same command lines and expects the same output.
