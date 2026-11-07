# Run each CLI command as its own action, as the TypeScript CLI does

## Overview

The TypeScript CLI (`apps/cli/index.ts`, `apps/cli/src/cmd/secrets.ts`, `apps/cli/src/cmd/dbs.ts`) registers each command's own function as its commander action: `.action(initContext(addCommand))`, `.action(bugReportCommand)`, `.action(secretsAdd)`. `initContext` wraps a command: it reads the command's options, configures the log from `verbose` and `tools`, makes the command context and calls the command. The Zig CLI (`apps/cli-zig/index.zig`) does it differently: it has 66 hand-written `xAction` functions (`addAction`, `checkAction`, ...) that only copy the parsed values into a `ParseOutcome` union stored in `IProgramState.outcome`, and `run` then switches over that union (about 70 arms) to call the command. The log's `--verbose` and `--tools` have to be carried from the parser to `run` separately, which has led to state copied in `preActionHook`. This plan removes the `xAction` functions, `ParseOutcome` and `run`'s dispatch switch, and registers each command's function as its action through one generic wrapper that, like `initContext` in TypeScript, reads the command's options, configures the one log from them and calls the command with that log.

## Issues

## Steps

1. **Get the CLI back to a compiling baseline before the change.** `apps/cli-zig/index.zig` is part way through an earlier change: `run` reads `state.verbose` and `state.tools`, which `IProgramState` no longer has. In `run`, configure the log with `.{}` options in place of `state.verbose` and `state.tools`, so the CLI compiles, and leave `preActionHook` without any log option copying. Run `mise exec -- zig build` at the repository root; it must compile. This baseline is replaced in step 5.

2. **Write the generic option reader.** In a new file `apps/cli-zig/src/lib/command-options.zig`, add `pub fn commandOptions(comptime Options: type, values: *const OptionValues) Options`, which builds a command's typed options from commander's option values by the names of the fields of `Options`:
   - a field of type `IBaseCommandOptions` is filled with the existing `baseOptions(values)` (move `baseOptions`, `flagValue` and `textValue` from `index.zig` into this file and import them in `index.zig`);
   - a `?bool` field is read with `flagValue` under the field's name, a `?[]const u8` field with `textValue`, and a `bool` or `[]const u8` field the same way with the option's default when it is absent;
   - any other field type is a compile error naming the type and the field, so a command whose options cannot be read this way fails to build rather than silently getting defaults.
   Give the file its header comment and a test file `apps/cli-zig/src/test/command-options.test.zig` registered with the other CLI tests. Compile and run `mise exec -- zig build test`.

3. **Write the generic action wrappers.** In a new file `apps/cli-zig/src/lib/command-action.zig`, add the commander action listeners that stand in for `initContext(command)` and for a bare `command`:
   - `ICommandRuntime`: what every command needs from `main` and cannot get from the command line, set up once in `run`: the allocator, the Io, the console log `main` starts with, `main_log` (so `main`'s error handling uses the configured log), and the media tools. It is the CLI's top-level extremity, built in `run` and handed to commander as the action's context.
   - `pub fn withContext(comptime Options: type, comptime command: anytype) ...`: returns a listener with commander's action signature (`fn (*const ICommandRuntime, []const ArgumentValue, *const OptionValues, *Command) anyerror!void`) that reads `Options` with `commandOptions`, configures the log once with `log_setup.configureLog` from the options' `base.verbose` and `base.tools`, sets `main_log`, calls `initContext` with that log and calls the command with the allocator, Io, log, context, the positional arguments and the options.
   - `pub fn withLog(comptime Options: type, comptime command: anytype) ...`: the same without `initContext`, for the commands TypeScript registers bare (`bug`, `examples`, `hash`, `hash-cache hash-file`, `hash-cache add`, `news`, `tools`, `version`, the `secrets` and `dbs` commands). It configures the log from the options' `verbose` and `tools` when the options have them, and with the log's defaults otherwise.
   - Positional arguments: a command that takes them (`add [files...]`, `check <files...>`, `hash <file>`, `set-origin <origin>` and the rest) is given them as the parameter after the context (or after the log, with `withLog`), exactly as commander passes `args`; follow each command's existing signature in `apps/cli-zig/src/cmd/` and change a command's signature only where it cannot otherwise be called the same way as its siblings, and say which in the step's summary.
   Test both wrappers in `apps/cli-zig/src/test/command-action.test.zig` with a small command of the test's own that records the log options and arguments it is given. Compile and run `mise exec -- zig build test`.

4. **Register each command's function as its action.** In `createProgram` in `apps/cli-zig/index.zig`, replace every `.action(state, xAction)` with `.action(runtime, withContext(IXCommandOptions, xCommand))` or `.action(runtime, withLog(IXCommandOptions, xCommand))`, choosing the wrapper the TypeScript registration of that command uses (`initContext(...)` in `apps/cli/index.ts` means `withContext`, a bare function means `withLog`). Do the same for the `secrets` and `dbs` groups, which are registered in `apps/cli-zig/src/cmd/secrets.zig` and `apps/cli-zig/src/cmd/dbs.zig` or wherever their `.action` calls are. Commands that print the notifications first (the `if (state.notificationsQuiet) |quiet| printNotifications(...)` in each arm of `run`) keep doing so: move that into the wrappers, after the log is configured, so every command gets it as it does now. Compile.

5. **Remove what the actions replaced.** In `apps/cli-zig/index.zig`, delete the 66 `xAction` functions, the `ParseOutcome` union and its payload types that only existed to carry parsed values (`IAddParsed`, `ICheckParsed`, `IHashParsed`, `IInfoParsed` and the rest; keep any type a command function itself takes), `IProgramState.outcome`, `parseCommandLine`'s outcome handling, and `run`'s dispatch switch. `run` keeps what is not a command: building the program, running `program.parse`, and turning commander's help, version, failure and exit results into the exit codes they give now (`isHelpCode`, `isQuietCommanderError`, the `versionOption` callback, `processExit`). The configure-the-log block that `run` has before its dispatch goes, since the wrappers configure the log. Compile.

6. **Update the CLI's tests.** `apps/cli-zig/src/test/index.test.zig` calls `parseCommandLine` and checks the `ParseOutcome` it returns. Change those tests to check what the commands are called with instead, through the wrappers with test commands, or through the existing command tests where they already cover it; a test whose only subject was the `ParseOutcome` value is removed with its subject. Fix every other test the compiler names. Run `mise exec -- zig build test`; it must pass.

7. **Run the CLI's smoke tests.** Run `bun run test:cli:zig`. Every test must pass, including help, version, an unknown command and an unknown option, which exercise the exit codes `run` still produces.

8. **Update the documentation.** Update `apps/cli-zig/README.md` (or the doc under `docs/` that describes how the Zig CLI is put together; find it with a search for `ParseOutcome` and `parseCommandLine`) to say that each command is its own commander action through `withContext` or `withLog`, as in the TypeScript CLI, that those wrappers configure the one log from the command's `--verbose` and `--tools`, and how to add a command: declare its options type, write its function and register it with the matching wrapper.

## Unit Tests

- `commandOptions` fills `IBaseCommandOptions` fields with the base options, `?bool` and `?[]const u8` fields from the option values by name, leaves an absent optional field null, and gives an absent non-optional field its default (`command-options.test.zig`).
- `withContext` reads the options, configures the log with the command's `--verbose` and `--tools`, sets `main_log` to that log and calls the command with its positional arguments and options (`command-action.test.zig`).
- `withLog` does the same without making a command context, and uses the log's defaults for a command whose options have no `verbose` or `tools` (`command-action.test.zig`).
- `run` still returns the exit codes of help, `--version`, an unknown command and an unknown option (`index.test.zig`).

## Smoke Tests

- `bun run test:cli:zig`: every Zig CLI smoke suite, which runs real commands end to end (add, check, verify, replicate, export, secrets, dbs and the rest) and so covers each command's registration.

## Verify

- `mise exec -- zig build` at the repository root compiles with no errors.
- `mise exec -- zig build test` passes.
- `bun run test:cli:zig` passes.
- `grep -n "Action(state" apps/cli-zig/index.zig` finds nothing, and `grep -n "ParseOutcome" -r apps/cli-zig` finds nothing.
- `bun run tev` (plain, no `--force`) exits with code 0.

## Notes

- The log: with every command going through `withContext` or `withLog`, the log is configured once, from the running command's own options, in one place, and no options are copied into `IProgramState` and no list of commands names where each keeps its options. This replaces the `preActionHook` copy and the hand-written list of commands that were tried for the log.
- `commandOptions` reads the options by the field names of each command's options type at compile time. The alternative, a hand-written reader per command, is what the 66 `xAction` functions are now. Making a field type it cannot read a compile error keeps it from silently dropping an option.
- `ICommandRuntime` holds the console log `main` starts with. That is the CLI's top level, the one place a log may be held, and every command is passed its log as a parameter from there.
- The `secrets` and `dbs` groups are registered in their own files in TypeScript; follow wherever their Zig `.action` calls are now.
- TypeScript configures a file log only for the commands wrapped in `initContext`. The human asked for every command to be given the one configured log, so `withLog` configures it too.
