//
// Port of apps/cli/index.ts: the `psi` entry point.
// Only the `replicate` (alias `rep`) and `verify` (alias `ver`) commands are implemented in Zig; every other
// command line (including no arguments, help and --version) is handed to the TypeScript CLI (src/main.zig).
// Help requests for replicate and verify are also handed over, so the help text is commander's own.
//

const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");

pub const picocolors = @import("src/lib/picocolors.zig");
pub const format = @import("src/lib/format.zig");
pub const terminal_utils = @import("src/lib/terminal-utils.zig");
pub const log = @import("src/lib/log.zig");
pub const file_logger = @import("src/lib/file-logger.zig");
pub const process_argv = @import("src/lib/process-argv.zig");
pub const tty = @import("src/lib/tty.zig");
pub const config = @import("src/lib/config.zig");
pub const commander = @import("src/lib/commander.zig");
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
const OptionSpec = commander.OptionSpec;
const Option = commander.Option;
const OptionValues = commander.OptionValues;
const CommanderError = commander.CommanderError;
const IReplicateCommandOptions = replicate.IReplicateCommandOptions;
const IVerifyCommandOptions = verify.IVerifyCommandOptions;
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;
const initContext = init_cmd.initContext;
const replicateCommand = replicate.replicateCommand;
const verifyCommand = verify.verifyCommand;
const exit = node_utils.termination.exit;
const FatalError = utils.fatal_error.FatalError;
const console = utils.console;

// The option tuples of index.ts (only those used by replicate and verify).
pub const dbOption: OptionSpec = .{ .flags = "--db <path>", .description = "The directory that contains the media file database" };
pub const destDbOption: OptionSpec = .{ .flags = "--dest <path>", .description = "The destination directory that specifies the target database" };
pub const keyOption: OptionSpec = .{ .flags = "-k, --key <keyfile>", .description = "Path to the private key file for encryption." };
pub const destKeyOption: OptionSpec = .{ .flags = "--dk, --dest-key <keyfile>", .description = "Path to destination encryption key file" };
pub const generateKeyOption: OptionSpec = .{ .flags = "-g, --generate-key", .description = "Generate encryption keys if they don't exist.", .defaultValue = false };
pub const verboseOption: OptionSpec = .{ .flags = "-v, --verbose", .description = "Enables verbose logging.", .defaultValue = false };
pub const toolsOption: OptionSpec = .{ .flags = "--tools", .description = "Enables output from media processing tools (ImageMagick, ffmpeg, etc.).", .defaultValue = false };
pub const yesOption: OptionSpec = .{ .flags = "-y, --yes", .description = "Non-interactive mode. Use command line arguments and defaults.", .defaultValue = false };
pub const cwdOption: OptionSpec = .{ .flags = "--cwd <path>", .description = "Set the current working directory for directory selection prompts. Defaults to the current directory from your shell/terminal. This is mostly for testing/debugging." };
pub const workersOption: OptionSpec = .{ .flags = "--workers <number>", .description = "Number of worker threads to use for parallel processing (default: number of CPU cores)" };
pub const timeoutOption: OptionSpec = .{ .flags = "--timeout <ms>", .description = "Task timeout in milliseconds (default: 600000 = 10 minutes)" };
// Not ported: sourceDbOption, sessionIdOption, recordsOption, allOption, fullOption, maxOption, dryRunOption
// (not used by replicate or verify).

//
// The options of the program itself (`.option('--version', ...)` and `.option('--debug', ...)`).
//
pub const programOptions = [_]OptionSpec{
    .{ .flags = "--version", .description = "output the version number" },
    .{ .flags = "--debug", .description = "Enable debug REST API server" },
};

//
// A command implemented in Zig: its name, aliases, description and options, in declaration order.
//
pub const CommandSpec = struct {
    // The command name.
    name: []const u8,

    // The command alias.
    alias: []const u8,

    // The command description.
    description: []const u8,

    // The options of the command.
    options: []const OptionSpec,
};

//
// The replicate command (`program.command("replicate").alias("rep")...`).
//
pub const replicateSpec: CommandSpec = .{
    .name = "replicate",
    .alias = "rep",
    .description = "Replicates an asset database from source to destination location.",
    .options = &.{
        dbOption,
        destDbOption,
        keyOption,
        destKeyOption,
        generateKeyOption,
        .{ .flags = "-p, --path <path>", .description = "Replicate only files matching this path (file or directory)" },
        .{ .flags = "--partial", .description = "Create a partial replica: copy only metadata and structure; asset files are fetched on demand from origin." },
        .{ .flags = "--full", .description = "Create a full replica: copy all original, display, and thumbnail files (default when --yes is used)." },
        .{ .flags = "--force", .description = "Proceed with replication without confirmation, even if destination database exists, and allow replication between databases with different IDs (THIS IS DANGEROUS, use it carefully, use it rarely)" },
        verboseOption,
        toolsOption,
        yesOption,
        cwdOption,
    },
};

//
// The verify command (`program.command("verify").alias("ver")...`).
//
pub const verifySpec: CommandSpec = .{
    .name = "verify",
    .alias = "ver",
    .description = "Verifies the integrity of the media file database by checking file hashes.",
    .options = &.{
        dbOption,
        keyOption,
        verboseOption,
        toolsOption,
        yesOption,
        .{ .flags = "--full", .description = "Force full verification (bypass cached hash optimization)", .defaultValue = false },
        .{ .flags = "-p, --path <path>", .description = "Verify only files matching this path (file or directory)" },
        workersOption,
        timeoutOption,
        cwdOption,
    },
};

// Not ported: the other commands, the help text (addHelpText, getCommandExamplesHelp) and the help command
// (the TypeScript CLI handles them).

//
// The result of parsing the command line.
//
pub const ParseOutcome = union(enum) {
    // The command line is handed to the TypeScript CLI.
    delegate,

    // Commander reports an error and the process exits with 1.
    failure: CommanderError,

    // Run the replicate command with these options.
    replicate: IReplicateCommandOptions,

    // Run the verify command with these options.
    verify: IVerifyCommandOptions,
};

//
// Parses the options of a command declaration.
//
fn parseOptionSpecs(allocator: std.mem.Allocator, specs: []const OptionSpec) ![]const Option {
    const options = try allocator.alloc(Option, specs.len);
    for (specs, 0..) |spec, index| {
        options[index] = Option.init(spec);
    }
    return options;
}

//
// The long flags that commander suggests for an unknown option of a command: the command's options and
// help option, then the program's options and help option.
//
fn candidateFlags(allocator: std.mem.Allocator, commandOptions: []const Option, programOptionList: []const Option) ![]const []const u8 {
    var flags: std.ArrayList([]const u8) = .empty;
    for (commandOptions) |option| {
        if (option.long) |longFlag| {
            try flags.append(allocator, longFlag);
        }
    }
    try flags.append(allocator, "--help");
    for (programOptionList) |option| {
        if (option.long) |longFlag| {
            try flags.append(allocator, longFlag);
        }
    }
    try flags.append(allocator, "--help");
    return flags.items;
}

//
// True when the argument is the help option (`-h, --help`).
//
fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

//
// Gets a string option value.
//
fn textValue(values: *const OptionValues, name: []const u8) ?[]const u8 {
    const value = values.get(name) orelse return null;
    return switch (value) {
        .text => |text| text,
        .flag => null,
    };
}

//
// Gets a boolean option value.
//
fn flagValue(values: *const OptionValues, name: []const u8) ?bool {
    const value = values.get(name) orelse return null;
    return switch (value) {
        .flag => |flag| flag,
        .text => true,
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
// Parses the user arguments like commander does for `program.parseAsync(process.argv)`, for the
// replicate and verify commands. Anything else (other commands, no command, help, --version) is delegated.
//
pub fn parseCommandLine(allocator: std.mem.Allocator, userArgs: []const []const u8) !ParseOutcome {
    const programOptionList = try parseOptionSpecs(allocator, &programOptions);

    // The program parses first: its options are recognised anywhere before "--".
    var programValues: OptionValues = .empty;
    const programParse = switch (try commander.parseOptions(allocator, programOptionList, userArgs, &programValues)) {
        .parsed => |parsed| parsed,
        .failure => |failure| return .{ .failure = failure },
    };
    if (programValues.get("version") != null) {
        // The --version option prints the version (the TypeScript CLI does it).
        return .delegate;
    }
    if (programParse.operands.len == 0) {
        return .delegate;
    }

    const commandName = programParse.operands[0];
    const spec: CommandSpec = if (std.mem.eql(u8, commandName, replicateSpec.name) or std.mem.eql(u8, commandName, replicateSpec.alias))
        replicateSpec
    else if (std.mem.eql(u8, commandName, verifySpec.name) or std.mem.eql(u8, commandName, verifySpec.alias))
        verifySpec
    else
        return .delegate;

    // The subcommand parses the unknown arguments of the program.
    const commandOptions = try parseOptionSpecs(allocator, spec.options);
    var values: OptionValues = .empty;
    for (commandOptions) |option| {
        if (option.defaultValue) |defaultValue| {
            try values.put(allocator, try option.attributeName(allocator), .{ .flag = defaultValue });
        }
    }
    const commandParse = switch (try commander.parseOptions(allocator, commandOptions, programParse.unknown, &values)) {
        .parsed => |parsed| parsed,
        .failure => |failure| return .{ .failure = failure },
    };
    var operands: std.ArrayList([]const u8) = .empty;
    try operands.appendSlice(allocator, programParse.operands[1..]);
    try operands.appendSlice(allocator, commandParse.operands);

    // Help is shown by the TypeScript CLI.
    for (commandParse.unknown) |arg| {
        if (isHelpFlag(arg)) {
            return .delegate;
        }
    }

    if (commandParse.unknown.len > 0) {
        return .{ .failure = try commander.unknownOptionError(allocator, commandParse.unknown[0], try candidateFlags(allocator, commandOptions, programOptionList)) };
    }
    if (operands.items.len > 0) {
        return .{ .failure = try commander.excessArgumentsError(allocator, spec.name, 0, operands.items.len) };
    }

    if (std.mem.eql(u8, spec.name, replicateSpec.name)) {
        return .{ .replicate = .{
            .base = baseOptions(&values),
            .dest = textValue(&values, "dest"),
            .destKey = textValue(&values, "destKey"),
            .generateKey = flagValue(&values, "generateKey"),
            .path = textValue(&values, "path"),
            .force = flagValue(&values, "force"),
            .partial = flagValue(&values, "partial"),
            .full = flagValue(&values, "full"),
        } };
    }
    return .{ .verify = .{
        .base = baseOptions(&values),
        .full = flagValue(&values, "full"),
        .path = textValue(&values, "path"),
    } };
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
    const outcome = try parseCommandLine(allocator, userArgs);
    switch (outcome) {
        .delegate => return delegate.delegateToTypeScript(allocator, io, userArgs),
        .failure => |failure| {
            // Commander writes the error to stderr; main exits quietly with 1 for these codes and
            // rethrows any other error (like an option missing its value) to main().catch.
            console.@"error"(failure.message);
            if (isQuietCommanderError(failure.code)) {
                exit(io, 1);
            }
            return utils.errors.throwError("{s}", .{failure.message});
        },
        .replicate => |parsed| {
            var options = parsed;
            // The preAction hook (skipped only for the news and bug commands).
            try print_notifications.printNotifications(allocator, io);
            const context = try initContext(allocator, io, options.base);
            try replicateCommand(allocator, io, context, &options);
        },
        .verify => |parsed| {
            var options = parsed;
            // The preAction hook (skipped only for the news and bug commands).
            try print_notifications.printNotifications(allocator, io);
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
