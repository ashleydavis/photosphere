//
// Port of apps/cli/index.ts: the `psi` entry point.
// Only the `replicate` (alias `rep`) and `verify` (alias `ver`) commands are implemented in Zig; every other
// command line (including no arguments, program help and --version) is handed to the TypeScript CLI (src/main.zig).
// The help of replicate and verify is rendered here by the commander port (src/lib/commander.zig).
//

const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");

pub const picocolors = @import("src/lib/picocolors.zig");
pub const format = @import("src/lib/format.zig");
pub const terminal_utils = @import("src/lib/terminal-utils.zig");
pub const console_output = @import("src/lib/console-output.zig");
pub const log = @import("src/lib/log.zig");
pub const file_logger = @import("src/lib/file-logger.zig");
pub const process_argv = @import("src/lib/process-argv.zig");
pub const tty = @import("src/lib/tty.zig");
pub const config = @import("src/lib/config.zig");
pub const commander = @import("src/lib/commander.zig");
pub const examples = @import("src/examples.zig");
pub const prompts = @import("src/lib/clack/prompts.zig");
pub const wrap_ansi = @import("src/lib/clack/third-party/wrap-ansi.zig");
pub const string_width = @import("src/lib/clack/third-party/string-width.zig");
pub const readline = @import("src/lib/clack/third-party/readline.zig");
pub const sisteransi = @import("src/lib/clack/third-party/sisteransi.zig");
pub const clack_core = @import("src/lib/clack/core/index.zig");
pub const ensure_tools = @import("src/lib/ensure-tools.zig");
pub const installation_instructions = @import("src/lib/installation-instructions.zig");
pub const directory_picker = @import("src/lib/directory-picker.zig");
pub const storage_helper = @import("src/lib/storage-helper.zig");
pub const init_cmd = @import("src/lib/init-cmd.zig");
pub const worker_pool = @import("src/lib/worker-pool.zig");
pub const worker_log_bun = @import("src/lib/worker-log-bun.zig");
pub const replicate = @import("src/cmd/replicate.zig");
pub const verify = @import("src/cmd/verify.zig");
pub const delegate = @import("src/main.zig");
pub const print_notifications = @import("src/lib/print-notifications.zig");
pub const check_for_updates = @import("src/lib/check-for-updates.zig");
pub const check_for_news = @import("src/lib/check-for-news.zig");

const pc = picocolors;
const Command = commander.Command;
const OptionValue = commander.OptionValue;
const OptionValues = commander.OptionValues;
const ArgumentValue = commander.ArgumentValue;
const CommanderError = commander.CommanderError;
const IReplicateCommandOptions = replicate.IReplicateCommandOptions;
const IVerifyCommandOptions = verify.IVerifyCommandOptions;
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;
const initContext = init_cmd.initContext;
const replicateCommand = replicate.replicateCommand;
const verifyCommand = verify.verifyCommand;
const getCommandExamplesHelp = examples.getCommandExamplesHelp;
const exit = node_utils.termination.exit;
const FatalError = utils.fatal_error.FatalError;
const console = utils.console;

//
// An option as declared in index.ts: the `[flags, description, default?]` tuples passed to `.option(...)`.
//
pub const IOptionSpec = struct {
    // The flags, e.g. "-k, --key <keyfile>".
    flags: []const u8,

    // The help text.
    description: []const u8,

    // The default value (the third tuple element), or null when there is none.
    defaultValue: ?OptionValue = null,
};

// The option tuples of index.ts (only those used by replicate and verify).
pub const dbOption: IOptionSpec = .{
    .flags = "--db <path>",
    .description = "The directory that contains the media file database",
};
pub const destDbOption: IOptionSpec = .{
    .flags = "--dest <path>",
    .description = "The destination directory that specifies the target database",
};
pub const keyOption: IOptionSpec = .{
    .flags = "-k, --key <keyfile>",
    .description = "Path to the private key file for encryption.",
};
pub const destKeyOption: IOptionSpec = .{
    .flags = "--dk, --dest-key <keyfile>",
    .description = "Path to destination encryption key file",
};
pub const generateKeyOption: IOptionSpec = .{
    .flags = "-g, --generate-key",
    .description = "Generate encryption keys if they don't exist.",
    .defaultValue = .{ .boolean = false },
};
pub const verboseOption: IOptionSpec = .{
    .flags = "-v, --verbose",
    .description = "Enables verbose logging.",
    .defaultValue = .{ .boolean = false },
};
pub const toolsOption: IOptionSpec = .{
    .flags = "--tools",
    .description = "Enables output from media processing tools (ImageMagick, ffmpeg, etc.).",
    .defaultValue = .{ .boolean = false },
};
pub const yesOption: IOptionSpec = .{
    .flags = "-y, --yes",
    .description = "Non-interactive mode. Use command line arguments and defaults.",
    .defaultValue = .{ .boolean = false },
};
pub const cwdOption: IOptionSpec = .{
    .flags = "--cwd <path>",
    .description = "Set the current working directory for directory selection prompts. Defaults to the current directory from your shell/terminal. This is mostly for testing/debugging.",
};
pub const workersOption: IOptionSpec = .{
    .flags = "--workers <number>",
    .description = "Number of worker threads to use for parallel processing (default: number of CPU cores)",
};
pub const timeoutOption: IOptionSpec = .{
    .flags = "--timeout <ms>",
    .description = "Task timeout in milliseconds (default: 600000 = 10 minutes)",
};
// Not ported: sourceDbOption, sessionIdOption, databaseIdOption, recordsOption, allOption, fullOption, maxOption,
// dryRunOption (not used by replicate or verify).

//
// Adds an option tuple to a command (`.option(...tuple)`).
//
fn optionFrom(command: *Command, spec: IOptionSpec) *Command {
    return command.option(spec.flags, spec.description, spec.defaultValue);
}

//
// The command a parsed command line runs.
//
pub const ParseOutcome = union(enum) {
    // The command line is handed to the TypeScript CLI.
    delegate,

    // Commander stopped the parse: it has written the help or the error.
    failure: CommanderError,

    // Run the replicate command with these options.
    replicate: IReplicateCommandOptions,

    // Run the verify command with these options.
    verify: IVerifyCommandOptions,
};

//
// What the program's hook and actions leave for `run` to do once the command line is parsed. The actions of
// index.ts run inside `parseAsync`; here parsing and running are split so that `run` does the same work, in the
// same order, after the parse returns.
//
pub const IProgramState = struct {
    // Allocates the parsed options.
    allocator: std.mem.Allocator,

    // The quiet flag the preAction hook prints the notifications with, or null when the hook did not ask for them.
    notificationsQuiet: ?bool = null,

    // The command the action asks to run.
    outcome: ParseOutcome = .delegate,
};

//
// The `--version` option callback: index.ts prints the version and exits. That is left to the TypeScript CLI,
// so the command line is handed to it.
//
fn versionOption(state: *IProgramState, value: ?[]const u8, previous: ?OptionValue) !?OptionValue {
    _ = state;
    _ = value;
    _ = previous;
    return error.DelegateToTypeScript;
}

//
// Print update + news notifications before every command. Skipped for the `news`
// command itself (which renders its own full-feed listing) and for the `bug` command
// (which captures clean output for the bug report). --quiet suppresses them for any
// command, which is what a caller reading the output by machine wants. Network/parse
// errors are swallowed inside printNotifications(), so the hook never blocks the user.
//
fn preActionHook(state: *IProgramState, thisCommand: *Command, actionCommand: *Command) !void {
    const skipForCommands = [_][]const u8{ "news", "bug" };
    for (skipForCommands) |skipped| {
        if (std.mem.eql(u8, actionCommand.getName(), skipped)) {
            return;
        }
    }
    const quiet = thisCommand.opts().get("quiet");
    state.notificationsQuiet = quiet != null and quiet.? == .boolean and quiet.?.boolean;
}

//
// Gets a string option value.
//
fn textValue(values: *const OptionValues, name: []const u8) ?[]const u8 {
    const value = values.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        .boolean => null,
    };
}

//
// Gets a boolean option value.
//
fn flagValue(values: *const OptionValues, name: []const u8) ?bool {
    const value = values.get(name) orelse return null;
    return switch (value) {
        .boolean => |flag| flag,
        .string => true,
    };
}

//
// Converts the parsed values to the options shared by every command.
//
fn baseOptions(values: *const OptionValues) IBaseCommandOptions {
    return .{
        .db = textValue(values, "db"),
        .key = textValue(values, "key"),
        .verbose = flagValue(values, "verbose"),
        .tools = flagValue(values, "tools"),
        .yes = flagValue(values, "yes"),
        .cwd = textValue(values, "cwd"),
        .sessionId = textValue(values, "sessionId"),
        .workers = textValue(values, "workers"),
        .timeout = textValue(values, "timeout"),
    };
}

//
// The action of the replicate command (`initContext(replicateCommand)`): `run` calls initContext and the command.
//
fn replicateAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .replicate = .{
            .base = baseOptions(options),
            .dest = textValue(options, "dest"),
            .destKey = textValue(options, "destKey"),
            .generateKey = flagValue(options, "generateKey"),
            .path = textValue(options, "path"),
            .force = flagValue(options, "force"),
            .partial = flagValue(options, "partial"),
            .full = flagValue(options, "full"),
        },
    };
}

//
// The action of the verify command (`initContext(verifyCommand)`): `run` calls initContext and the command.
//
fn verifyAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .verify = .{
            .base = baseOptions(options),
            .full = flagValue(options, "full"),
            .path = textValue(options, "path"),
        },
    };
}

//
// Defines the psi program like main() in index.ts, with the commands implemented in Zig.
//
pub fn createProgram(allocator: std.mem.Allocator, state: *IProgramState) !*Command {
    const program = Command.init(allocator, "");
    _ = program
        .name("psi")
        .description("The Photosphere CLI tool for managing your media file database.")
        .optionWithArgParser("--version", "output the version number", state, versionOption)
        .option("--debug", "Enable debug REST API server", null)
        .option("-q, --quiet", "Suppress optional output (update and news notifications). Give it before the command name.", null)
        // Not ported: .addHelpText('after', ...) (the program help is shown by the TypeScript CLI).
        .exitOverride() // Prevent commander from calling process.exit
        .addHelpCommand(false); // Disable default help command so we can add it in alphabetical order

    _ = program.hook(.preAction, state, preActionHook);

    // Not ported: the commands before replicate (the TypeScript CLI runs them).

    const replicateDefinition = program
        .command("replicate", .{})
        .alias("rep")
        .description("Replicates an asset database from source to destination location.");
    _ = optionFrom(replicateDefinition, dbOption);
    _ = optionFrom(replicateDefinition, destDbOption);
    _ = optionFrom(replicateDefinition, keyOption);
    _ = optionFrom(replicateDefinition, destKeyOption);
    _ = optionFrom(replicateDefinition, generateKeyOption);
    _ = replicateDefinition
        .option("-p, --path <path>", "Replicate only files matching this path (file or directory)", null)
        .option("--partial", "Create a partial replica: copy only metadata and structure; asset files are fetched on demand from origin.", null)
        .option("--full", "Create a full replica: copy all original, display, and thumbnail files (default when --yes is used).", null)
        .option("--force", "Proceed with replication without confirmation, even if destination database exists, and allow replication between databases with different IDs (THIS IS DANGEROUS, use it carefully, use it rarely)", null);
    _ = optionFrom(replicateDefinition, verboseOption);
    _ = optionFrom(replicateDefinition, toolsOption);
    _ = optionFrom(replicateDefinition, yesOption);
    _ = optionFrom(replicateDefinition, cwdOption);
    _ = replicateDefinition
        .addHelpText(.after, try getCommandExamplesHelp(allocator, "replicate"))
        .action(state, replicateAction);

    // Not ported: summary and sync (the TypeScript CLI runs them).

    const verifyDefinition = program
        .command("verify", .{})
        .alias("ver")
        .description("Verifies the integrity of the media file database by checking file hashes.");
    _ = optionFrom(verifyDefinition, dbOption);
    _ = optionFrom(verifyDefinition, keyOption);
    _ = optionFrom(verifyDefinition, verboseOption);
    _ = optionFrom(verifyDefinition, toolsOption);
    _ = optionFrom(verifyDefinition, yesOption);
    _ = verifyDefinition
        .option("--full", "Force full verification (bypass cached hash optimization)", .{ .boolean = false })
        .option("-p, --path <path>", "Verify only files matching this path (file or directory)", null);
    _ = optionFrom(verifyDefinition, workersOption);
    _ = optionFrom(verifyDefinition, timeoutOption);
    _ = optionFrom(verifyDefinition, cwdOption);
    _ = verifyDefinition
        .addHelpText(.after, try getCommandExamplesHelp(allocator, "verify"))
        .action(state, verifyAction);

    // Not ported: the commands after verify, the secrets and dbs command groups (the TypeScript CLI runs them).
    return program;
}

//
// Parses the command line like `program.parseAsync(process.argv)`. The program parses its own options first
// (as commander's `_parseCommand` does), which tells which command the command line names: when that is not a
// command implemented in Zig (other commands, no command, help, --version), the command line is handed to the
// TypeScript CLI.
//
pub fn parseCommandLine(program: *Command, state: *IProgramState, userArgs: []const []const u8) !ParseOutcome {
    const programParse = program.parseOptions(userArgs) catch |err| {
        if (err == error.DelegateToTypeScript) {
            return .delegate;
        }
        return err;
    };
    if (programParse.operands.len == 0 or program.findCommand(programParse.operands[0]) == null) {
        return .delegate;
    }

    program.parse(userArgs) catch |err| {
        if (err == error.CommanderError) {
            return .{ .failure = program.getCommanderError().? };
        }
        return err;
    };
    return state.outcome;
}

//
// True for the commander error codes of help, which main() turns into an exit with code 0.
//
fn isHelpCode(code: []const u8) bool {
    return std.mem.eql(u8, code, "commander.help") or std.mem.eql(u8, code, "commander.helpDisplayed");
}

//
// True for the commander error codes that main() turns into a quiet exit with code 1.
//
fn isQuietCommanderError(code: []const u8) bool {
    const quietCodes = [_][]const u8{ "commander.missingArgument", "commander.unknownOption", "commander.unknownCommand", "commander.excessArguments" };
    for (quietCodes) |quietCode| {
        if (std.mem.eql(u8, code, quietCode)) {
            return true;
        }
    }
    return false;
}

//
// Runs the command line: parses it, then runs the command or delegates it. Returns the exit code for
// delegated command lines; commands exit the process themselves.
//
fn run(allocator: std.mem.Allocator, io: std.Io, userArgs: []const []const u8) !u8 {
    var state: IProgramState = .{
        .allocator = allocator,
    };
    const program = try createProgram(allocator, &state);
    const outcome = try parseCommandLine(program, &state, userArgs);
    switch (outcome) {
        .delegate => return delegate.delegateToTypeScript(allocator, io, userArgs),
        .failure => |failure| {
            // Commander has written the help or the error. main() exits with 0 for help and quietly with 1 for
            // these codes, and rethrows any other error (like an option missing its value) to main().catch.
            // (Its exit with 0 when there are no arguments is not reached: no arguments are handed to TypeScript.)
            if (isHelpCode(failure.code)) {
                exit(io, 0);
            }
            if (isQuietCommanderError(failure.code)) {
                exit(io, 1);
            }
            return utils.errors.throwError("{s}", .{failure.message});
        },
        .replicate => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try replicateCommand(allocator, io, context, &options);
        },
        .verify => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try verifyCommand(allocator, io, context, &options);
        },
    }
    return 0;
}

//
// Handles errors in a consistent way.
//
pub fn handleError(allocator: std.mem.Allocator, err: anyerror, errorType: ?[]const u8) void {
    if (FatalError.isInstance(err)) {
        const red = pc.red(allocator, utils.errors.errorMessage(err)) catch utils.errors.errorMessage(err);
        const message = std.fmt.allocPrint(allocator, "\n\n{s}", .{red}) catch red;
        utils.log.log.@"error"(message);
        return;
    }

    if (errorType) |kind| {
        const message = std.fmt.allocPrint(allocator, "An {s} error occurred", .{kind}) catch "An error occurred";
        utils.log.log.exception(message, err);
    }
    else {
        utils.log.log.exception("An unknown error occurred", err);
    }

    console.log("");
    console.log("If you believe this behaviour is a bug, please report it with the following command:");
    console.log(pc.yellow(allocator, "   psi bug") catch "   psi bug");
}

// Not ported: the 'uncaughtException' and 'unhandledRejection' handlers (Zig has no uncaught exceptions;
// every error is returned to main, which handles it like `main().catch`).

//
// The entry point: sets up the process globals, then runs the command line (`main().catch(...)`).
//
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    tty.initConsole();
    node_utils.process_env.setEnvironMap(init.environ_map);
    const arguments = try init.minimal.args.toSlice(allocator);
    const argv = try allocator.alloc([]const u8, arguments.len);
    for (arguments, 0..) |argument, index| {
        argv[index] = argument;
    }
    process_argv.setArgv(argv);

    const exitCode = run(allocator, io, process_argv.userArgs()) catch |err| {
        handleError(allocator, err, null);
        exit(io, 1);
    };
    std.process.exit(exitCode);
}
