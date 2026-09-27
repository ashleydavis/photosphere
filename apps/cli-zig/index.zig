//
// Port of apps/cli/index.ts: the `psi` entry point.
// Only the `add` (alias `a`), `compare` (alias `cmp`), `database-id`, `export` (alias `exp`), `info` (alias
// `inf`), `init` (alias `i`), `list` (aliases `ls` and `l`), `origin`, `remove` (alias `rm`), `replicate` (alias
// `rep`), `root-hash`, `set-origin`, `summary` (alias `sum`), `verify` (alias `ver`) and `version` commands and
// the `--version` option are ported; the other commands are not registered yet, so commander reports them as
// unknown commands.
// The help of these commands is rendered here by the commander port (src/lib/commander.zig).
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
pub const add = @import("src/cmd/add.zig");
pub const replicate = @import("src/cmd/replicate.zig");
pub const init_command = @import("src/cmd/init.zig");
pub const compare = @import("src/cmd/compare.zig");
pub const remove = @import("src/cmd/remove.zig");
pub const export_command = @import("src/cmd/export.zig");
pub const info = @import("src/cmd/info.zig");
pub const list = @import("src/cmd/list.zig");
pub const origin = @import("src/cmd/origin.zig");
pub const set_origin = @import("src/cmd/set-origin.zig");
pub const root_hash = @import("src/cmd/root-hash.zig");
pub const database_id = @import("src/cmd/database-id.zig");
pub const summary = @import("src/cmd/summary.zig");
pub const verify = @import("src/cmd/verify.zig");
pub const version_cmd = @import("src/cmd/version.zig");
pub const print_notifications = @import("src/lib/print-notifications.zig");
pub const check_for_updates = @import("src/lib/check-for-updates.zig");
pub const check_for_news = @import("src/lib/check-for-news.zig");

const pc = picocolors;
const Command = commander.Command;
const OptionValue = commander.OptionValue;
const OptionValues = commander.OptionValues;
const ArgumentValue = commander.ArgumentValue;
const CommanderError = commander.CommanderError;
const IAddCommandOptions = add.IAddCommandOptions;
const addCommand = add.addCommand;
const IReplicateCommandOptions = replicate.IReplicateCommandOptions;
const ISummaryCommandOptions = summary.ISummaryCommandOptions;
const IVerifyCommandOptions = verify.IVerifyCommandOptions;
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;
const initContext = init_cmd.initContext;
const replicateCommand = replicate.replicateCommand;
const initCommand = init_command.initCommand;
const IInitCommandOptions = init_command.IInitCommandOptions;
const IRemoveCommandOptions = remove.IRemoveCommandOptions;
const removeCommand = remove.removeCommand;
const ICompareCommandOptions = compare.ICompareCommandOptions;
const compareCommand = compare.compareCommand;
const IExportCommandOptions = export_command.IExportCommandOptions;
const exportCommand = export_command.exportCommand;
const IInfoCommandOptions = info.IInfoCommandOptions;
const infoCommand = info.infoCommand;
const IListCommandOptions = list.IListCommandOptions;
const listCommand = list.listCommand;
const IOriginCommandOptions = origin.IOriginCommandOptions;
const originCommand = origin.originCommand;
const ISetOriginCommandOptions = set_origin.ISetOriginCommandOptions;
const setOriginCommand = set_origin.setOriginCommand;
const IRootHashCommandOptions = root_hash.IRootHashCommandOptions;
const rootHashCommand = root_hash.rootHashCommand;
const IDatabaseIdCommandOptions = database_id.IDatabaseIdCommandOptions;
const databaseIdCommand = database_id.databaseIdCommand;
const summaryCommand = summary.summaryCommand;
const verifyCommand = verify.verifyCommand;
const versionCommand = version_cmd.versionCommand;
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

// The option tuples of index.ts (only those used by the ported commands).
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
pub const sessionIdOption: IOptionSpec = .{
    .flags = "--session-id <id>",
    .description = "Set session identifier for write lock tracking. Defaults to a random UUID.",
};
pub const databaseIdOption: IOptionSpec = .{
    .flags = "--database-id <id>",
    .description = "Create the database with this identity instead of a new one, so it is related to the database that already has that identity and the two can sync. Get it from `psi database-id`.",
};
pub const dryRunOption: IOptionSpec = .{
    .flags = "--dry-run",
    .description = "Run without making any database changes (merkle tree and metadata updates are skipped)",
    .defaultValue = .{ .boolean = false },
};
pub const fullOption: IOptionSpec = .{
    .flags = "--full",
    .description = "Show all differences without truncation.",
    .defaultValue = .{ .boolean = false },
};
pub const maxOption: IOptionSpec = .{
    .flags = "--max <number>",
    .description = "Maximum number of items to show in each category (default: 10)",
};
// Not ported: sourceDbOption, recordsOption, allOption (not used by the ported commands).

//
// Adds an option tuple to a command (`.option(...tuple)`).
//
fn optionFrom(command: *Command, spec: IOptionSpec) *Command {
    return command.option(spec.flags, spec.description, spec.defaultValue);
}

//
// What the add command runs with: its files and its options (TypeScript: the arguments commander passes the action).
//
pub const IAddParsed = struct {
    // The media files (or directories) to add.
    paths: []const []const u8,

    // The options of the command.
    options: IAddCommandOptions,
};

//
// What the set-origin command runs with: its path and its options (TypeScript: the arguments commander passes the
// action).
//
pub const ISetOriginParsed = struct {
    // Path or URI of the origin database.
    path: []const u8,

    // The options of the command.
    options: ISetOriginCommandOptions,
};

//
// What the remove command runs with: its asset ID and options (TypeScript: the arguments commander passes the
// action).
//
pub const IRemoveParsed = struct {
    // The ID of the asset to remove.
    assetId: []const u8,

    // The options of the command.
    options: IRemoveCommandOptions,
};

//
// What the export command runs with: its asset ID, output path and options (TypeScript: the arguments commander
// passes the action).
//
pub const IExportParsed = struct {
    // The ID of the asset to export.
    assetId: []const u8,

    // The path where the asset should be exported.
    outputPath: []const u8,

    // The options of the command.
    options: IExportCommandOptions,
};

//
// What the info command runs with: its inputs and its options (TypeScript: the arguments commander passes the action).
//
pub const IInfoParsed = struct {
    // The file paths, asset IDs or hashes to show.
    inputs: []const []const u8,

    // The options of the command.
    options: IInfoCommandOptions,
};

//
// The command a parsed command line runs.
//
pub const ParseOutcome = union(enum) {

    // Commander stopped the parse: it has written the help or the error.
    failure: CommanderError,

    // Run the add command with these paths and options.
    add: IAddParsed,

    // Run the remove command with this asset and options.
    remove: IRemoveParsed,

    // Run the compare command with these options.
    compare: ICompareCommandOptions,

    // Run the export command with this asset, output path and options.
    @"export": IExportParsed,

    // Run the info command with these inputs and options.
    info: IInfoParsed,

    // Run the list command with these options.
    list: IListCommandOptions,

    // Run the replicate command with these options.
    replicate: IReplicateCommandOptions,

    // Run the origin command with these options.
    origin: IOriginCommandOptions,

    // Run the set-origin command with this path and these options.
    setOrigin: ISetOriginParsed,

    // Run the root-hash command with these options.
    rootHash: IRootHashCommandOptions,

    // Run the database-id command with these options.
    databaseId: IDatabaseIdCommandOptions,

    // Run the summary command with these options.
    summary: ISummaryCommandOptions,

    // Run the verify command with these options.
    verify: IVerifyCommandOptions,

    // Run the init command with these options.
    init: IInitCommandOptions,

    // Run the version command.
    version,

    // The --version option was given: print the version and exit.
    versionOption,
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

    // The command the action asks to run (null until an action runs).
    outcome: ?ParseOutcome = null,
};

//
// The `--version` option callback: index.ts prints the version and exits there and then. The parse is stopped
// here and `run` prints the version and exits.
//
fn versionOption(state: *IProgramState, value: ?[]const u8, previous: ?OptionValue) !?OptionValue {
    _ = value;
    _ = previous;
    state.outcome = .versionOption;
    return error.VersionOption;
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
// The action of the add command (`initContext(addCommand)`): `run` calls initContext and the command.
//
fn addAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = command;

    // [files...] is variadic, so commander always passes it as a list.
    const paths = args[0].list;
    state.outcome = .{
        .add = .{
            .paths = paths,
            .options = .{
                .base = baseOptions(options),
                .dryRun = flagValue(options, "dryRun"),
                .watch = flagValue(options, "watch"),
                .cleanup = flagValue(options, "cleanup"),
            },
        },
    };
}

//
// The action of the init command (`initContext(initCommand)`): `run` calls initContext and the command.
//
fn initAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .init = .{
            .base = baseOptions(options),
            .generateKey = flagValue(options, "generateKey"),
            .databaseId = textValue(options, "databaseId"),
        },
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
// The action of the compare command (`initContext(compareCommand)`): `run` calls initContext and the command.
//
fn compareAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .compare = .{
            .base = baseOptions(options),
            .dest = textValue(options, "dest"),
            .destKey = textValue(options, "destKey"),
            .full = flagValue(options, "full"),
            .max = textValue(options, "max"),
        },
    };
}

//
// The action of the remove command (`initContext(removeCommand)`): `run` calls initContext and the command.
//
fn removeAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = command;
    state.outcome = .{
        .remove = .{
            .assetId = args[0].string,
            .options = .{
                .base = baseOptions(options),
            },
        },
    };
}

//
// The action of the export command (`initContext(exportCommand)`): `run` calls initContext and the command.
//
fn exportAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = command;
    state.outcome = .{
        .@"export" = .{
            .assetId = args[0].string,
            .outputPath = args[1].string,
            .options = .{
                .base = baseOptions(options),
                .type = textValue(options, "type"),
            },
        },
    };
}

//
// The action of the info command (`initContext(infoCommand)`): `run` calls initContext and the command.
//
fn infoAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = command;

    // <files...> is variadic, so commander always passes it as a list.
    state.outcome = .{
        .info = .{
            .inputs = args[0].list,
            .options = .{
                .base = baseOptions(options),
            },
        },
    };
}

//
// The action of the list command (`initContext(listCommand)`): `run` calls initContext and the command.
//
fn listAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .list = .{
            .base = baseOptions(options),
            .pageSize = textValue(options, "pageSize"),
        },
    };
}

//
// The action of the origin command (`initContext(originCommand)`): `run` calls initContext and the command.
//
fn originAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .origin = .{
            .base = baseOptions(options),
        },
    };
}

//
// The action of the set-origin command
// (`initContext((ctx, path, options) => setOriginCommand(ctx, options, path))`): `run` calls initContext and the
// command.
//
fn setOriginAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = command;
    state.outcome = .{
        .setOrigin = .{
            .path = args[0].string,
            .options = .{
                .base = baseOptions(options),
            },
        },
    };
}

//
// The action of the root-hash command (`initContext(rootHashCommand)`): `run` calls initContext and the command.
//
fn rootHashAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .rootHash = .{
            .base = baseOptions(options),
        },
    };
}

//
// The action of the database-id command (`initContext(databaseIdCommand)`): `run` calls initContext and the
// command.
//
fn databaseIdAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .databaseId = .{
            .base = baseOptions(options),
        },
    };
}

//
// The action of the summary command (`initContext(summaryCommand)`): `run` calls initContext and the command.
//
fn summaryAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .summary = .{
            .base = baseOptions(options),
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
// The action of the version command (`versionCommand`): `run` calls the command.
//
fn versionAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = options;
    _ = command;
    state.outcome = .version;
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
        // Not ported yet: .addHelpText('after', ...).
        .exitOverride() // Prevent commander from calling process.exit
        .addHelpCommand(false); // Disable default help command so we can add it in alphabetical order

    _ = program.hook(.preAction, state, preActionHook);

    const addDefinition = program
        .command("add", .{})
        .alias("a")
        .description("Adds files and directories to the media file database, once or by watching for more.")
        .argument("[files...]", "The media files (or directories) to add. With --watch, the folders to watch: defaults to this operating system's photo folders.");
    _ = optionFrom(addDefinition, dbOption);
    _ = optionFrom(addDefinition, keyOption);
    _ = optionFrom(addDefinition, verboseOption);
    _ = optionFrom(addDefinition, toolsOption);
    _ = optionFrom(addDefinition, yesOption);
    _ = optionFrom(addDefinition, cwdOption);
    _ = optionFrom(addDefinition, sessionIdOption);
    _ = optionFrom(addDefinition, dryRunOption);
    _ = optionFrom(addDefinition, workersOption);
    _ = addDefinition
        .option("--watch", "Keep watching the named folders and import what turns up, rather than importing them once.", .{ .boolean = false })
        .option("--cleanup", "Delete the source files the database is confirmed to hold, once the import has finished.", .{ .boolean = false })
        .addHelpText(.after, try getCommandExamplesHelp(allocator, "add"))
        .action(state, addAction);

    // Not ported: bug and check.

    const compareDefinition = program
        .command("compare", .{})
        .alias("cmp")
        .description("Compares two databases to find the differences between them.");
    _ = optionFrom(compareDefinition, dbOption);
    _ = optionFrom(compareDefinition, destDbOption);
    _ = optionFrom(compareDefinition, keyOption);
    _ = optionFrom(compareDefinition, destKeyOption);
    _ = optionFrom(compareDefinition, verboseOption);
    _ = optionFrom(compareDefinition, yesOption);
    _ = optionFrom(compareDefinition, cwdOption);
    _ = optionFrom(compareDefinition, fullOption);
    _ = optionFrom(compareDefinition, maxOption);
    _ = compareDefinition
        .addHelpText(.after, try getCommandExamplesHelp(allocator, "compare"))
        .action(state, compareAction);

    // Not ported: examples.

    const exportDefinition = program
        .command("export", .{})
        .alias("exp")
        .description("Exports an asset by ID to a specified path.")
        .argument("<asset-id>", "The ID of the asset to export.")
        .argument("<output-path>", "The path where the asset should be exported.");
    _ = optionFrom(exportDefinition, dbOption);
    _ = optionFrom(exportDefinition, keyOption);
    _ = exportDefinition.option("-t, --type <type>", "Type of asset to export: original, display, or thumb (default: original)", .{ .string = "original" });
    _ = optionFrom(exportDefinition, verboseOption);
    _ = optionFrom(exportDefinition, yesOption);
    _ = optionFrom(exportDefinition, cwdOption);
    _ = exportDefinition
        .addHelpText(.after, try getCommandExamplesHelp(allocator, "export"))
        .action(state, exportAction);

    // Not ported: find-orphans, hash, hash-cache, debug and help.

    const infoDefinition = program
        .command("info", .{})
        .alias("inf")
        .description("Displays detailed information about media files including EXIF data, metadata, and technical specifications.");
    _ = optionFrom(infoDefinition, dbOption);
    _ = optionFrom(infoDefinition, verboseOption);
    _ = optionFrom(infoDefinition, toolsOption);
    _ = optionFrom(infoDefinition, yesOption);
    _ = optionFrom(infoDefinition, cwdOption);
    _ = infoDefinition
        .argument("<files...>", "File path(s), asset ID(s), or hash(es). --db is required only when looking up by asset ID or hash.")
        .addHelpText(.after, try getCommandExamplesHelp(allocator, "info"))
        .action(state, infoAction);

    const initDefinition = program
        .command("init", .{})
        .alias("i")
        .description("Initializes a new media file database.");
    _ = optionFrom(initDefinition, dbOption);
    _ = optionFrom(initDefinition, keyOption);
    _ = optionFrom(initDefinition, generateKeyOption);
    _ = optionFrom(initDefinition, verboseOption);
    _ = optionFrom(initDefinition, toolsOption);
    _ = optionFrom(initDefinition, yesOption);
    _ = optionFrom(initDefinition, cwdOption);
    _ = optionFrom(initDefinition, sessionIdOption);
    _ = optionFrom(initDefinition, databaseIdOption);
    _ = initDefinition
        .addHelpText(.after, try getCommandExamplesHelp(allocator, "init"))
        .action(state, initAction);

    const originDefinition = program
        .command("origin", .{})
        .description("Shows the origin database path (from .db/config.json).");
    _ = optionFrom(originDefinition, dbOption);
    _ = optionFrom(originDefinition, keyOption);
    _ = optionFrom(originDefinition, verboseOption);
    _ = optionFrom(originDefinition, yesOption);
    _ = optionFrom(originDefinition, cwdOption);
    _ = originDefinition.action(state, originAction);

    const setOriginDefinition = program
        .command("set-origin", .{})
        .description("Sets the origin database path in .db/config.json (used as default --dest or --source for sync, replicate, repair, compare).")
        .argument("<path>", "Path or URI of the origin database");
    _ = optionFrom(setOriginDefinition, dbOption);
    _ = optionFrom(setOriginDefinition, keyOption);
    _ = optionFrom(setOriginDefinition, verboseOption);
    _ = optionFrom(setOriginDefinition, yesOption);
    _ = optionFrom(setOriginDefinition, cwdOption);
    _ = setOriginDefinition.action(state, setOriginAction);

    // Not ported: consolidate.

    const listDefinition = program
        .command("list", .{})
        .alias("ls")
        .alias("l")
        .description("Lists all files in the database sorted by date (newest first) with pagination.");
    _ = optionFrom(listDefinition, dbOption);
    _ = optionFrom(listDefinition, keyOption);
    _ = optionFrom(listDefinition, verboseOption);
    _ = optionFrom(listDefinition, yesOption);
    _ = optionFrom(listDefinition, cwdOption);
    _ = listDefinition
        .option("--page-size <size>", "Number of files to display per page (default: 20)", .{ .string = "20" })
        .addHelpText(.after, try getCommandExamplesHelp(allocator, "list"))
        .action(state, listAction);

    // Not ported: mcp and news.

    const removeDefinition = program
        .command("remove", .{})
        .alias("rm")
        .description("Removes an asset from the database by ID, deleting the files for the asset.")
        .argument("<asset-id>", "The ID of the asset to remove.");
    _ = optionFrom(removeDefinition, dbOption);
    _ = optionFrom(removeDefinition, keyOption);
    _ = optionFrom(removeDefinition, verboseOption);
    _ = optionFrom(removeDefinition, yesOption);
    _ = optionFrom(removeDefinition, cwdOption);
    _ = removeDefinition
        .addHelpText(.after, try getCommandExamplesHelp(allocator, "remove"))
        .action(state, removeAction);

    // Not ported: remove-orphans and repair.

    const rootHashDefinition = program
        .command("root-hash", .{})
        .description("Displays the aggregate root hash of the database.");
    _ = optionFrom(rootHashDefinition, dbOption);
    _ = optionFrom(rootHashDefinition, keyOption);
    _ = optionFrom(rootHashDefinition, verboseOption);
    _ = optionFrom(rootHashDefinition, yesOption);
    _ = optionFrom(rootHashDefinition, cwdOption);
    _ = rootHashDefinition.action(state, rootHashAction);

    const databaseIdDefinition = program
        .command("database-id", .{})
        .description("Displays the database ID (UUID) of the database.");
    _ = optionFrom(databaseIdDefinition, dbOption);
    _ = optionFrom(databaseIdDefinition, keyOption);
    _ = optionFrom(databaseIdDefinition, verboseOption);
    _ = optionFrom(databaseIdDefinition, yesOption);
    _ = optionFrom(databaseIdDefinition, cwdOption);
    _ = databaseIdDefinition.action(state, databaseIdAction);

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

    const summaryDefinition = program
        .command("summary", .{})
        .alias("sum")
        .description("Displays a summary of the media file database including total files, size, and tree hash.");
    _ = optionFrom(summaryDefinition, dbOption);
    _ = optionFrom(summaryDefinition, keyOption);
    _ = optionFrom(summaryDefinition, verboseOption);
    _ = optionFrom(summaryDefinition, yesOption);
    _ = optionFrom(summaryDefinition, cwdOption);
    _ = summaryDefinition
        .addHelpText(.after, try getCommandExamplesHelp(allocator, "summary"))
        .action(state, summaryAction);

    // Not ported: sync.

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

    _ = program
        .command("version", .{})
        .description("Displays version information for psi and its dependencies.")
        .addHelpText(.after, try getCommandExamplesHelp(allocator, "version"))
        .action(state, versionAction);

    // Not ported: the commands after version, the secrets and dbs command groups.
    return program;
}

//
// Parses the command line like `program.parseAsync(process.argv)`.
//
pub fn parseCommandLine(program: *Command, state: *IProgramState, userArgs: []const []const u8) !ParseOutcome {
    program.parse(userArgs) catch |err| {
        if (err == error.VersionOption) {
            return .versionOption;
        }
        if (err == error.CommanderError) {
            return .{ .failure = program.getCommanderError().? };
        }
        return err;
    };
    return state.outcome.?;
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
// Runs the command line: parses it, then runs the command. Commands exit the process themselves.
//
fn run(allocator: std.mem.Allocator, io: std.Io, userArgs: []const []const u8) !u8 {
    var state: IProgramState = .{
        .allocator = allocator,
    };
    const program = try createProgram(allocator, &state);
    const outcome = try parseCommandLine(program, &state, userArgs);
    switch (outcome) {
        .failure => |failure| {
            // Commander has written the help or the error. main() exits with 0 for help and quietly with 1 for
            // these codes, exits with 0 when there are no arguments, and rethrows any other error (like an
            // option missing its value) to main().catch.
            if (isHelpCode(failure.code)) {
                exit(io, 0);
            }
            if (isQuietCommanderError(failure.code)) {
                exit(io, 1);
            }
            if (userArgs.len == 0) {
                exit(io, 0);
            }
            return utils.errors.throwError("{s}", .{failure.message});
        },
        .add => |parsed| {
            var options = parsed.options;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try addCommand(allocator, io, context, parsed.paths, &options);
        },
        .remove => |parsed| {
            var options = parsed.options;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try removeCommand(allocator, io, context, parsed.assetId, &options);
        },
        .compare => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try compareCommand(allocator, io, context, &options);
        },
        .@"export" => |parsed| {
            var options = parsed.options;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try exportCommand(allocator, io, context, parsed.assetId, parsed.outputPath, &options);
        },
        .info => |parsed| {
            var options = parsed.options;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try infoCommand(allocator, io, context, parsed.inputs, &options);
        },
        .replicate => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try replicateCommand(allocator, io, context, &options);
        },
        .list => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try listCommand(allocator, io, context, &options);
        },
        .origin => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try originCommand(allocator, io, context, &options);
        },
        .setOrigin => |parsed| {
            var options = parsed.options;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try setOriginCommand(allocator, io, context, &options, parsed.path);
        },
        .rootHash => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try rootHashCommand(allocator, io, context, &options);
        },
        .databaseId => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try databaseIdCommand(allocator, io, context, &options);
        },
        .summary => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try summaryCommand(allocator, io, context, &options);
        },
        .verify => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try verifyCommand(allocator, io, context, &options);
        },
        .init => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try initCommand(allocator, io, context, &options);
        },
        .version => {
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try versionCommand(allocator, io);
        },
        .versionOption => {
            console.log(config.version);
            exit(io, 0);
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
