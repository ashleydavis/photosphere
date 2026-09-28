//
// Port of apps/cli/index.ts: the `psi` entry point. Every command of index.ts is ported, with its aliases, and so is
// the `--version` option.
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
pub const repair = @import("src/cmd/repair.zig");
pub const find_orphans_command = @import("src/cmd/find-orphans.zig");
pub const find_orphans = @import("src/lib/find-orphans.zig");
pub const sync_watch = @import("src/lib/sync-watch.zig");
pub const sync = @import("src/cmd/sync.zig");
pub const consolidate = @import("src/cmd/consolidate.zig");
pub const encrypt = @import("src/cmd/encrypt.zig");
pub const decrypt = @import("src/cmd/decrypt.zig");
pub const news = @import("src/cmd/news.zig");
pub const bug = @import("src/cmd/bug.zig");
pub const open = @import("src/lib/third-party/open.zig");
pub const debug = @import("src/cmd/debug.zig");
pub const hash = @import("src/cmd/hash.zig");
pub const tools_cmd = @import("src/cmd/tools.zig");
pub const check = @import("src/cmd/check.zig");
pub const hash_cache = @import("src/cmd/hash-cache.zig");
pub const clear_cache = @import("src/cmd/clear-cache.zig");
pub const hash_cache_tools = @import("src/cmd/hash-cache-tools.zig");
pub const remove_orphans = @import("src/cmd/remove-orphans.zig");
pub const upgrade = @import("src/cmd/upgrade.zig");
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
pub const examples_cmd = @import("src/cmd/examples.zig");
pub const secrets = @import("src/cmd/secrets.zig");
pub const dbs = @import("src/cmd/dbs.zig");
pub const mcp = @import("src/cmd/mcp.zig");
pub const mcp_protocol = @import("src/lib/mcp/protocol.zig");
pub const mcp_input_schema = @import("src/lib/mcp/input-schema.zig");
pub const mcp_result = @import("src/lib/mcp/result.zig");
pub const mcp_types = @import("src/lib/mcp/types.zig");
pub const mcp_tools = @import("src/lib/mcp/tools/index.zig");
pub const spinner = @import("src/lib/spinner.zig");
pub const process_signals = @import("src/lib/process-signals.zig");
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
const IRepairCommandOptions = repair.IRepairCommandOptions;
const repairCommand = repair.repairCommand;
const IFindOrphansCommandOptions = find_orphans_command.IFindOrphansCommandOptions;
const findOrphansCommand = find_orphans_command.findOrphansCommand;
const IRemoveOrphansCommandOptions = remove_orphans.IRemoveOrphansCommandOptions;
const removeOrphansCommand = remove_orphans.removeOrphansCommand;
const IUpgradeCommandOptions = upgrade.IUpgradeCommandOptions;
const upgradeCommand = upgrade.upgradeCommand;
const ISyncCommandOptions = sync.ISyncCommandOptions;
const syncCommand = sync.syncCommand;
const IConsolidateCommandOptions = consolidate.IConsolidateCommandOptions;
const consolidateCommand = consolidate.consolidateCommand;
const IEncryptCommandOptions = encrypt.IEncryptCommandOptions;
const encryptCommand = encrypt.encryptCommand;
const IDecryptCommandOptions = decrypt.IDecryptCommandOptions;
const decryptCommand = decrypt.decryptCommand;
const newsCommand = news.newsCommand;
const IBugReportCommandOptions = bug.IBugReportCommandOptions;
const bugReportCommand = bug.bugReportCommand;
const IDebugMerkleTreeCommandOptions = debug.IDebugMerkleTreeCommandOptions;
const IDebugFindCollisionsCommandOptions = debug.IDebugFindCollisionsCommandOptions;
const IDebugFindDuplicatesCommandOptions = debug.IDebugFindDuplicatesCommandOptions;
const IDebugRemoveDuplicatesCommandOptions = debug.IDebugRemoveDuplicatesCommandOptions;
const debugMerkleTreeCommand = debug.debugMerkleTreeCommand;
const debugFindCollisionsCommand = debug.debugFindCollisionsCommand;
const debugFindDuplicatesCommand = debug.debugFindDuplicatesCommand;
const debugRemoveDuplicatesCommand = debug.debugRemoveDuplicatesCommand;
const debugBuildSortIndexCommand = debug.debugBuildSortIndexCommand;
const debugBuildFilesTreeCommand = debug.debugBuildFilesTreeCommand;
const IHashCommandOptions = hash.IHashCommandOptions;
const hashCommand = hash.hashCommand;
const IToolsCommandOptions = tools_cmd.IToolsCommandOptions;
const toolsCommand = tools_cmd.toolsCommand;
const ICheckCommandOptions = check.ICheckCommandOptions;
const checkCommand = check.checkCommand;
const IHashCacheCommandOptions = hash_cache.IHashCacheCommandOptions;
const hashCacheCommand = hash_cache.hashCacheCommand;
const IClearCacheCommandOptions = clear_cache.IClearCacheCommandOptions;
const clearCacheCommand = clear_cache.clearCacheCommand;
const IHashCacheToolOptions = hash_cache_tools.IHashCacheToolOptions;
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
const IMcpCommandOptions = mcp.IMcpCommandOptions;
const mcpCommand = mcp.mcpCommand;
const verifyCommand = verify.verifyCommand;
const versionCommand = version_cmd.versionCommand;
const getCommandExamplesHelp = examples.getCommandExamplesHelp;
const MAIN_EXAMPLES = examples.MAIN_EXAMPLES;
const examplesCommand = examples_cmd.examplesCommand;
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
pub const sourceDbOption: IOptionSpec = .{
    .flags = "--source <path>",
    .description = "The source directory that contains the database to repair from",
};
pub const recordsOption: IOptionSpec = .{
    .flags = "--records",
    .description = "Show JSON for each internal record in each shard.",
    .defaultValue = .{ .boolean = false },
};
pub const allOption: IOptionSpec = .{
    .flags = "--all",
    .description = "Show all fields and full values (don't truncate) when displaying records.",
    .defaultValue = .{ .boolean = false },
};

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
// What the check command runs with: its files and its options (TypeScript: the arguments commander passes the
// action).
//
pub const ICheckParsed = struct {
    // The media files (or directories) to check.
    paths: []const []const u8,

    // The options of the command.
    options: ICheckCommandOptions,
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
// What the consolidate command runs with: its remote and options (TypeScript: the arguments commander passes the
// action).
//
pub const IConsolidateParsed = struct {
    // Path or URI of the remote database.
    remote: []const u8,

    // The options of the command.
    options: IConsolidateCommandOptions,
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
// What the hash command runs with: its file path and its options (TypeScript: the arguments commander passes the
// action).
//
pub const IHashParsed = struct {
    // The file path to hash.
    filePath: []const u8,

    // The options of the command.
    options: IHashCommandOptions,
};

//
// What the hash-cache add command runs with: its file and its options (TypeScript: the arguments commander passes
// the action).
//
pub const IHashCacheAddParsed = struct {
    // The file to hash and record.
    file: []const u8,

    // The options of the command.
    options: IHashCacheToolOptions,
};

//
// What the hash-cache set and set-source commands run with: the key, hash, length and options (TypeScript: the
// arguments commander passes the action).
//
pub const IHashCacheSetParsed = struct {
    // The path (set) or photo library source id (set-source) to record the hash against.
    key: []const u8,

    // The hash, in hex.
    hash: []const u8,

    // The length of the file in bytes, as typed.
    length: []const u8,

    // The options of the command.
    options: IHashCacheToolOptions,
};

//
// What the hash-cache get, get-asset-id and remove commands run with: the key and options (TypeScript: the
// arguments commander passes the action).
//
pub const IHashCacheKeyParsed = struct {
    // The key of the entry.
    key: []const u8,

    // The options of the command.
    options: IHashCacheToolOptions,
};

//
// The command a parsed command line runs.
//
pub const ParseOutcome = union(enum) {

    // Commander stopped the parse: it has written the help or the error.
    failure: CommanderError,

    // Run the add command with these paths and options.
    add: IAddParsed,

    // Run the check command with these paths and options.
    check: ICheckParsed,

    // Run the repair command with these options.
    repair: IRepairCommandOptions,

    // Run the remove command with this asset and options.
    remove: IRemoveParsed,

    // Run the find-orphans command with these options.
    findOrphans: IFindOrphansCommandOptions,

    // Run the remove-orphans command with these options.
    removeOrphans: IRemoveOrphansCommandOptions,

    // Run the upgrade command with these options.
    upgrade: IUpgradeCommandOptions,

    // Run the sync command with these options.
    sync: ISyncCommandOptions,

    // Run the consolidate command with this remote and these options.
    consolidate: IConsolidateParsed,

    // Run the encrypt command with these options.
    encrypt: IEncryptCommandOptions,

    // Run the decrypt command with these options.
    decrypt: IDecryptCommandOptions,

    // Run the bug command with these options.
    bug: IBugReportCommandOptions,

    // Run the news command.
    news,

    // Run the debug merkle-tree command with these options.
    debugMerkleTree: IDebugMerkleTreeCommandOptions,

    // Run the debug find-collisions command with these options.
    debugFindCollisions: IDebugFindCollisionsCommandOptions,

    // Run the debug find-duplicates command with these options.
    debugFindDuplicates: IDebugFindDuplicatesCommandOptions,

    // Run the debug remove-duplicates command with these options.
    debugRemoveDuplicates: IDebugRemoveDuplicatesCommandOptions,

    // Run the debug build-sort-index command with these options.
    debugBuildSortIndex: IBaseCommandOptions,

    // Run the debug build-files-tree command with these options.
    debugBuildFilesTree: IBaseCommandOptions,

    // Run the hash command with this file path and these options.
    hash: IHashParsed,

    // Run the tools command with these options.
    tools: IToolsCommandOptions,

    // Run the hash-cache show command with these options.
    hashCacheShow: IHashCacheCommandOptions,

    // Run the hash-cache clear command with these options.
    hashCacheClear: IClearCacheCommandOptions,

    // Run the hash-cache hash-file command on this file.
    hashCacheHashFile: []const u8,

    // Run the hash-cache add command with this file and these options.
    hashCacheAdd: IHashCacheAddParsed,

    // Run the hash-cache set command with this key, hash, length and options.
    hashCacheSet: IHashCacheSetParsed,

    // Run the hash-cache set-source command with this source id, hash, length and options.
    hashCacheSetSource: IHashCacheSetParsed,

    // Run the hash-cache get command with this key and options.
    hashCacheGet: IHashCacheKeyParsed,

    // Run the hash-cache get-asset-id command with this key and options.
    hashCacheGetAssetId: IHashCacheKeyParsed,

    // Run the hash-cache remove command with this key and options.
    hashCacheRemove: IHashCacheKeyParsed,

    // Run the hash-cache list command with these options.
    hashCacheList: IHashCacheToolOptions,

    // Run the hash-cache count command with these options.
    hashCacheCount: IHashCacheToolOptions,

    // Run the hash-cache dir command with these options.
    hashCacheDir: IHashCacheToolOptions,

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

    // Run the examples command.
    examples,

    // Run the help command: show the help of the named command, or of the program when null.
    help: ?[]const u8,

    // Run the mcp command with these options.
    mcp: IMcpCommandOptions,

    // Run `secrets add` with these options.
    secretsAdd: secrets.ISecretsAddOptions,

    // Run `secrets list`.
    secretsList,

    // Run `secrets view` with these options.
    secretsView: secrets.ISecretsViewOptions,

    // Run `secrets edit` with these options.
    secretsEdit: secrets.ISecretsEditOptions,

    // Run `secrets remove` with these options.
    secretsRemove: secrets.ISecretsRemoveOptions,

    // Run `secrets clear` with these options.
    secretsClear: secrets.ISecretsClearOptions,

    // Run `secrets import` with these options.
    secretsImport: secrets.ISecretsImportOptions,

    // Run `secrets send` with these options.
    secretsSend: secrets.ISecretsSendOptions,

    // Run `secrets receive` with these options.
    secretsReceive: secrets.ISecretsReceiveOptions,

    // Run `dbs list`.
    dbsList,

    // Run `dbs add` with these options.
    dbsAdd: dbs.IDbsAddOptions,

    // Run `dbs view` with these options.
    dbsView: dbs.IDbsViewOptions,

    // Run `dbs edit` with these options.
    dbsEdit: dbs.IDbsEditOptions,

    // Run `dbs remove` with these options.
    dbsRemove: dbs.IDbsRemoveOptions,

    // Run `dbs clear` with these options.
    dbsClear: dbs.IDbsClearOptions,

    // Run `dbs send` with these options.
    dbsSend: dbs.IDbsSendOptions,

    // Run `dbs receive` with these options.
    dbsReceive: dbs.IDbsReceiveOptions,

    // A command that does not exit through `.exitOverride()` (the secrets and dbs groups) called
    // `process.exit` with this exit code, after writing its help or its error.
    processExit: u8,

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
// The action of the check command (`initContext(checkCommand)`): `run` calls initContext and the command.
//
fn checkAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = command;

    // <files...> is variadic, so commander always passes it as a list.
    const paths = args[0].list;
    state.outcome = .{
        .check = .{
            .paths = paths,
            .options = .{
                .base = baseOptions(options),
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
// The action of the repair command (`initContext(repairCommand)`): `run` calls initContext and the command.
//
fn repairAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .repair = .{
            .base = baseOptions(options),
            .source = textValue(options, "source"),
            .sourceKey = textValue(options, "sourceKey"),
            .full = flagValue(options, "full"),
        },
    };
}

//
// The action of the find-orphans command (`initContext(findOrphansCommand)`): `run` calls initContext and the
// command.
//
fn findOrphansAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .findOrphans = .{
            .base = baseOptions(options),
        },
    };
}

//
// The action of the remove-orphans command (`initContext(removeOrphansCommand)`): `run` calls initContext and the
// command.
//
fn removeOrphansAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .removeOrphans = .{
            .base = baseOptions(options),
        },
    };
}

//
// The action of the sync command (`initContext(syncCommand)`): `run` calls initContext and the command.
//
fn syncAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .sync = .{
            .base = baseOptions(options),
            .dest = textValue(options, "dest"),
            .destKey = textValue(options, "destKey"),
            .watch = flagValue(options, "watch"),
            .interval = textValue(options, "interval"),
        },
    };
}

//
// The action of the consolidate command
// (`initContext((ctx, remote, options) => consolidateCommand(ctx, remote, options))`): `run` calls initContext and the
// command.
//
fn consolidateAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = command;
    state.outcome = .{
        .consolidate = .{
            .remote = args[0].string,
            .options = .{
                .base = baseOptions(options),
                .destKey = textValue(options, "destKey"),
            },
        },
    };
}

//
// The action of the encrypt command (`initContext(encryptCommand)`): `run` calls initContext and the command.
//
fn encryptAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .encrypt = .{
            .base = baseOptions(options),
            .generateKey = flagValue(options, "generateKey"),
        },
    };
}

//
// The action of the decrypt command (`initContext(decryptCommand)`): `run` calls initContext and the command.
//
fn decryptAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .decrypt = .{
            .base = baseOptions(options),
        },
    };
}

//
// The action of the bug command (`bugReportCommand`): `run` calls the command. Commander stores `--no-browser`
// as the `browser` option, so `noBrowser` is never set, as in index.ts.
//
fn bugAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .bug = .{
            .verbose = flagValue(options, "verbose"),
            .tools = flagValue(options, "tools"),
            .yes = flagValue(options, "yes"),
            .noBrowser = flagValue(options, "noBrowser"),
        },
    };
}

//
// The action of the news command (`newsCommand`): `run` calls the command.
//
fn newsAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = options;
    _ = command;
    state.outcome = .news;
}

//
// The action of the debug merkle-tree command (`initContext(debugMerkleTreeCommand)`): `run` calls initContext and
// the command.
//
fn debugMerkleTreeAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .debugMerkleTree = .{
            .base = baseOptions(options),
            .records = flagValue(options, "records"),
            .all = flagValue(options, "all"),
        },
    };
}

//
// The action of the debug find-collisions command (`initContext(debugFindCollisionsCommand)`): `run` calls
// initContext and the command.
//
fn debugFindCollisionsAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .debugFindCollisions = .{
            .base = baseOptions(options),
            .output = textValue(options, "output"),
        },
    };
}

//
// The action of the debug find-duplicates command (`initContext(debugFindDuplicatesCommand)`): `run` calls
// initContext and the command.
//
fn debugFindDuplicatesAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .debugFindDuplicates = .{
            .base = baseOptions(options),
            .input = textValue(options, "input"),
            .output = textValue(options, "output"),
        },
    };
}

//
// The action of the debug remove-duplicates command (`initContext(debugRemoveDuplicatesCommand)`): `run` calls
// initContext and the command.
//
fn debugRemoveDuplicatesAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .debugRemoveDuplicates = .{
            .base = baseOptions(options),
            .input = textValue(options, "input"),
        },
    };
}

//
// The action of the debug build-sort-index command (`initContext(debugBuildSortIndexCommand)`): `run` calls
// initContext and the command.
//
fn debugBuildSortIndexAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .debugBuildSortIndex = baseOptions(options),
    };
}

//
// The action of the debug build-files-tree command (`initContext(debugBuildFilesTreeCommand)`): `run` calls
// initContext and the command.
//
fn debugBuildFilesTreeAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .debugBuildFilesTree = baseOptions(options),
    };
}

//
// The action of the hash command (`hashCommand`, without initContext): `run` calls the command.
//
fn hashAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = command;
    state.outcome = .{
        .hash = .{
            .filePath = args[0].string,
            .options = .{
                .verbose = flagValue(options, "verbose"),
                .yes = flagValue(options, "yes"),
                .key = textValue(options, "key"),
            },
        },
    };
}

//
// The action of the tools command (`toolsCommand`): `run` calls the command.
//
fn toolsAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .tools = .{
            .yes = flagValue(options, "yes"),
        },
    };
}

//
// The action of the hash-cache show command (`initContext(hashCacheCommand)`): `run` calls initContext and the
// command.
//
fn hashCacheShowAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .hashCacheShow = .{
            .base = baseOptions(options),
        },
    };
}

//
// The action of the hash-cache clear command (`initContext(clearCacheCommand)`): `run` calls initContext and the
// command.
//
fn hashCacheClearAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .hashCacheClear = .{
            .base = baseOptions(options),
        },
    };
}

//
// Converts the parsed values to the options of the hash cache tools. --db is a required option, so commander has
// checked that it has a value.
//
fn hashCacheToolOptions(values: *const OptionValues) IHashCacheToolOptions {
    return .{
        .db = textValue(values, "db").?,
    };
}

//
// The action of the hash-cache hash-file command (`hashFileCommand`): `run` calls the command.
//
fn hashCacheHashFileAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = options;
    _ = command;
    state.outcome = .{
        .hashCacheHashFile = args[0].string,
    };
}

//
// The action of the hash-cache add command (`hashCacheAddCommand`): `run` calls the command.
//
fn hashCacheAddAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = command;
    state.outcome = .{
        .hashCacheAdd = .{
            .file = args[0].string,
            .options = hashCacheToolOptions(options),
        },
    };
}

//
// The action of the hash-cache set command (`hashCacheSetCommand`): `run` calls the command.
//
fn hashCacheSetAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = command;
    state.outcome = .{
        .hashCacheSet = .{
            .key = args[0].string,
            .hash = args[1].string,
            .length = args[2].string,
            .options = hashCacheToolOptions(options),
        },
    };
}

//
// The action of the hash-cache set-source command (`hashCacheSetSourceCommand`): `run` calls the command.
//
fn hashCacheSetSourceAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = command;
    state.outcome = .{
        .hashCacheSetSource = .{
            .key = args[0].string,
            .hash = args[1].string,
            .length = args[2].string,
            .options = hashCacheToolOptions(options),
        },
    };
}

//
// The action of the hash-cache get command (`hashCacheGetCommand`): `run` calls the command.
//
fn hashCacheGetAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = command;
    state.outcome = .{
        .hashCacheGet = .{
            .key = args[0].string,
            .options = hashCacheToolOptions(options),
        },
    };
}

//
// The action of the hash-cache get-asset-id command (`hashCacheGetAssetIdCommand`): `run` calls the command.
//
fn hashCacheGetAssetIdAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = command;
    state.outcome = .{
        .hashCacheGetAssetId = .{
            .key = args[0].string,
            .options = hashCacheToolOptions(options),
        },
    };
}

//
// The action of the hash-cache remove command (`hashCacheRemoveCommand`): `run` calls the command.
//
fn hashCacheRemoveAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = command;
    state.outcome = .{
        .hashCacheRemove = .{
            .key = args[0].string,
            .options = hashCacheToolOptions(options),
        },
    };
}

//
// The action of the hash-cache list command (`hashCacheListCommand`): `run` calls the command.
//
fn hashCacheListAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .hashCacheList = hashCacheToolOptions(options),
    };
}

//
// The action of the hash-cache count command (`hashCacheCountCommand`): `run` calls the command.
//
fn hashCacheCountAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .hashCacheCount = hashCacheToolOptions(options),
    };
}

//
// The action of the hash-cache dir command (`hashCacheDirCommand`): `run` calls the command.
//
fn hashCacheDirAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .hashCacheDir = hashCacheToolOptions(options),
    };
}

//
// The action of the upgrade command (`initContext(upgradeCommand)`): `run` calls initContext and the command.
//
fn upgradeAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .upgrade = .{
            .base = baseOptions(options),
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
// The action of the examples command (`examplesCommand`): `run` calls the command.
//
fn examplesAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = options;
    _ = command;
    state.outcome = .examples;
}

//
// The action of the help command: `run` shows the help of the named command, or of the program.
//
fn helpAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = options;
    _ = command;
    state.outcome = .{
        .help = switch (args[0]) {
            .string => |commandName| commandName,
            .none, .list => null,
        },
    };
}

//
// The action of the mcp command (`initContext(mcpCommand)`): `run` calls initContext and the command.
//
fn mcpAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .mcp = .{
            .base = baseOptions(options),
        },
    };
}

//
// The help command of index.ts: shows the help of the command with this name or alias, or the help of the program
// when there is no name or no such command. Returns the error commander stops with once the help is written.
//
pub fn helpCommand(program: *Command, commandName: ?[]const u8) anyerror {
    if (commandName) |name| {
        if (program.findCommand(name)) |found| {
            return found.help(false);
        }
        else {
            const message = std.fmt.allocPrint(program.allocator, "Unknown command: {s}", .{name}) catch |err| {
                return err;
            };
            console.@"error"(message);
            return program.help(false);
        }
    }
    else {
        return program.help(false);
    }
}

//
// The text index.ts adds after the help of the program: how to get help, the main examples and the resources.
//
pub fn mainHelpText(allocator: std.mem.Allocator) ![]const u8 {
    var exampleLines: std.ArrayList([]const u8) = .empty;
    for (MAIN_EXAMPLES) |example| {
        var line: std.ArrayList(u8) = .empty;
        try line.appendSlice(allocator, "  ");
        try line.appendSlice(allocator, example.command);
        const length = commander.jsLength(example.command);
        if (length < 46) {
            try line.appendNTimes(allocator, ' ', 46 - length);
        }
        try line.append(allocator, ' ');
        try line.appendSlice(allocator, example.description);
        try exampleLines.append(allocator, line.items);
    }
    return std.fmt.allocPrint(allocator,
        \\
        \\
        \\Getting help:
        \\  {s}    Shows help for a particular command.
        \\  {s}              Shows help for all commands.
        \\
        \\Examples:
        \\{s}
        \\
        \\Resources:
        \\  🚀 Getting Started: https://github.com/ashleydavis/photosphere/wiki/Getting-Started
        \\  📖 Command Reference: https://github.com/ashleydavis/photosphere/wiki/Command-Reference
        \\  📚 Wiki: https://github.com/ashleydavis/photosphere/wiki
        \\  🐛 View Issues: https://github.com/ashleydavis/photosphere/issues
        \\  ➕ New Issue: https://github.com/ashleydavis/photosphere/issues/new
    , .{
        try pc.bold(allocator, "psi <command> --help"),
        try pc.bold(allocator, "psi --help"),
        try std.mem.join(allocator, "\n", exampleLines.items),
    });
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
        .addHelpText(.after, try mainHelpText(allocator))
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

    const bugDefinition = program
        .command("bug", .{})
        .description("Generates a bug report for GitHub with system information and logs.");
    _ = optionFrom(bugDefinition, verboseOption);
    _ = optionFrom(bugDefinition, yesOption);
    _ = bugDefinition
        .option("--no-browser", "Don't open the browser automatically", .{ .boolean = false })
        .addHelpText(.after, try getCommandExamplesHelp(allocator, "bug"))
        .action(state, bugAction);

    const checkDefinition = program
        .command("check", .{})
        .alias("chk")
        .description("Checks files and directories to see what has already been added to the media file database.")
        .argument("<files...>", "The media files (or directories) to add to the database.");
    _ = optionFrom(checkDefinition, dbOption);
    _ = optionFrom(checkDefinition, keyOption);
    _ = optionFrom(checkDefinition, verboseOption);
    _ = optionFrom(checkDefinition, toolsOption);
    _ = optionFrom(checkDefinition, yesOption);
    _ = optionFrom(checkDefinition, workersOption);
    _ = optionFrom(checkDefinition, timeoutOption);
    _ = optionFrom(checkDefinition, cwdOption);
    _ = checkDefinition
        .addHelpText(.after, try getCommandExamplesHelp(allocator, "check"))
        .action(state, checkAction);

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

    const examplesDefinition = program
        .command("examples", .{})
        .description("Shows usage examples for all CLI commands.");
    _ = optionFrom(examplesDefinition, yesOption);
    _ = examplesDefinition
        .addHelpText(.after, try getCommandExamplesHelp(allocator, "examples"))
        .action(state, examplesAction);

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

    const findOrphansDefinition = program
        .command("find-orphans", .{})
        .description("Find and list files that are no longer in the merkle tree.");
    _ = optionFrom(findOrphansDefinition, dbOption);
    _ = optionFrom(findOrphansDefinition, keyOption);
    _ = optionFrom(findOrphansDefinition, verboseOption);
    _ = optionFrom(findOrphansDefinition, yesOption);
    _ = optionFrom(findOrphansDefinition, cwdOption);
    _ = findOrphansDefinition
        .addHelpText(.after, try getCommandExamplesHelp(allocator, "find-orphans"))
        .action(state, findOrphansAction);

    const hashDefinition = program
        .command("hash", .{})
        .description("Compute the hash of a file using the same algorithm as the database.")
        .argument("<file-path>", "The file path to hash (supports fs:, s3:, and encrypted storage)");
    _ = optionFrom(hashDefinition, keyOption);
    _ = optionFrom(hashDefinition, verboseOption);
    _ = optionFrom(hashDefinition, yesOption);
    _ = optionFrom(hashDefinition, cwdOption);
    _ = hashDefinition
        .addHelpText(.after, try getCommandExamplesHelp(allocator, "hash"))
        .action(state, hashAction);

    //
    // Commands for inspecting and driving the local hash cache. The whole group is hidden: it is
    // for development and for the concurrency smoke test, not for end users, and it is documented
    // in the wiki rather than in the program help.
    //
    const hashCacheDefinition = program
        .command("hash-cache", .{ .hidden = true })
        .description("Inspect and manage a database's hash cache.");

    //
    // Every one of these names a database, because there is one hash cache per database: an entry
    // records the id its file has in that database, and one entry cannot hold the ids of several.
    // The two user-facing commands resolve --db the way every other command does; the development
    // tools below take the path as given, because they act on the cache alone and a test script
    // points them at a path rather than at a database that exists.
    //
    const hashCacheToolDbOption: IOptionSpec = .{
        .flags = "--db <path>",
        .description = "The directory that contains the media file database",
    };

    const hashCacheShowDefinition = hashCacheDefinition
        .command("show", .{})
        .description("Display information about a database's hash cache.");
    _ = optionFrom(hashCacheShowDefinition, dbOption);
    _ = optionFrom(hashCacheShowDefinition, keyOption);
    _ = optionFrom(hashCacheShowDefinition, verboseOption);
    _ = optionFrom(hashCacheShowDefinition, yesOption);
    _ = optionFrom(hashCacheShowDefinition, cwdOption);
    _ = hashCacheShowDefinition.action(state, hashCacheShowAction);

    const hashCacheClearDefinition = hashCacheDefinition
        .command("clear", .{})
        .description("Clear a database's hash cache to force re-hashing of files.");
    _ = optionFrom(hashCacheClearDefinition, dbOption);
    _ = optionFrom(hashCacheClearDefinition, keyOption);
    _ = optionFrom(hashCacheClearDefinition, verboseOption);
    _ = optionFrom(hashCacheClearDefinition, yesOption);
    _ = optionFrom(hashCacheClearDefinition, cwdOption);
    _ = hashCacheClearDefinition.action(state, hashCacheClearAction);

    _ = hashCacheDefinition
        .command("hash-file <file>", .{})
        .description("Compute the SHA-256 hash of a file without touching the cache.")
        .action(state, hashCacheHashFileAction);

    _ = hashCacheDefinition
        .command("add <file>", .{})
        .description("Hash a file and record it in the hash cache.")
        .requiredOption(hashCacheToolDbOption.flags, hashCacheToolDbOption.description, null)
        .action(state, hashCacheAddAction);

    _ = hashCacheDefinition
        .command("set <path> <hash> <length>", .{})
        .description("Record a hash in the hash cache against an arbitrary path.")
        .requiredOption(hashCacheToolDbOption.flags, hashCacheToolDbOption.description, null)
        .action(state, hashCacheSetAction);

    _ = hashCacheDefinition
        .command("set-source <source-id> <hash> <length>", .{})
        .description("Record a hash in the hash cache against a photo library source id.")
        .requiredOption(hashCacheToolDbOption.flags, hashCacheToolDbOption.description, null)
        .action(state, hashCacheSetSourceAction);

    _ = hashCacheDefinition
        .command("get <path>", .{})
        .description("Print the cached hash for a key. Exits 1 when it is not cached.")
        .requiredOption(hashCacheToolDbOption.flags, hashCacheToolDbOption.description, null)
        .action(state, hashCacheGetAction);

    _ = hashCacheDefinition
        .command("get-asset-id <path>", .{})
        .description("Print the asset id recorded against a key. Exits 1 when there is none.")
        .requiredOption(hashCacheToolDbOption.flags, hashCacheToolDbOption.description, null)
        .action(state, hashCacheGetAssetIdAction);

    _ = hashCacheDefinition
        .command("remove <path>", .{})
        .description("Remove a key from the hash cache. Exits 1 when it was not cached.")
        .requiredOption(hashCacheToolDbOption.flags, hashCacheToolDbOption.description, null)
        .action(state, hashCacheRemoveAction);

    _ = hashCacheDefinition
        .command("list", .{})
        .description("Print the key of every entry in the hash cache, one per line.")
        .requiredOption(hashCacheToolDbOption.flags, hashCacheToolDbOption.description, null)
        .action(state, hashCacheListAction);

    _ = hashCacheDefinition
        .command("count", .{})
        .description("Print how many entries the hash cache holds.")
        .requiredOption(hashCacheToolDbOption.flags, hashCacheToolDbOption.description, null)
        .action(state, hashCacheCountAction);

    _ = hashCacheDefinition
        .command("dir", .{})
        .description("Print the directory holding a database's hash cache.")
        .requiredOption(hashCacheToolDbOption.flags, hashCacheToolDbOption.description, null)
        .action(state, hashCacheDirAction);

    const debugCommand = program
        .command("debug", .{})
        .description("Debug commands for inspecting database internals.");

    const debugMerkleTree = debugCommand
        .command("merkle-tree", .{})
        .description("Visualize all merkle trees in a media file database.");
    _ = optionFrom(debugMerkleTree, dbOption);
    _ = optionFrom(debugMerkleTree, keyOption);
    _ = optionFrom(debugMerkleTree, verboseOption);
    _ = optionFrom(debugMerkleTree, yesOption);
    _ = optionFrom(debugMerkleTree, cwdOption);
    _ = optionFrom(debugMerkleTree, recordsOption);
    _ = optionFrom(debugMerkleTree, allOption);
    _ = debugMerkleTree.action(state, debugMerkleTreeAction);

    const debugFindCollisions = debugCommand
        .command("find-collisions", .{})
        .description("Finds hash collisions (same hash, different asset IDs) and writes results to JSON file.");
    _ = optionFrom(debugFindCollisions, dbOption);
    _ = optionFrom(debugFindCollisions, keyOption);
    _ = optionFrom(debugFindCollisions, verboseOption);
    _ = optionFrom(debugFindCollisions, yesOption);
    _ = optionFrom(debugFindCollisions, cwdOption);
    _ = debugFindCollisions
        .option("-o, --output <path>", "Output JSON file path (default: collisions.json)", .{ .string = "collisions.json" })
        .action(state, debugFindCollisionsAction);

    const debugFindDuplicates = debugCommand
        .command("find-duplicates", .{})
        .description("Finds duplicate assets by comparing file content. Reads collisions JSON from find-collisions.");
    _ = optionFrom(debugFindDuplicates, dbOption);
    _ = optionFrom(debugFindDuplicates, keyOption);
    _ = optionFrom(debugFindDuplicates, verboseOption);
    _ = optionFrom(debugFindDuplicates, yesOption);
    _ = optionFrom(debugFindDuplicates, cwdOption);
    _ = debugFindDuplicates
        .option("-i, --input <path>", "Input JSON file path from find-collisions command (default: collisions.json)", .{ .string = "collisions.json" })
        .option("-o, --output <path>", "Output JSON file path (default: duplicates.json)", .{ .string = "duplicates.json" })
        .action(state, debugFindDuplicatesAction);

    const debugRemoveDuplicates = debugCommand
        .command("remove-duplicates", .{})
        .description("Removes duplicate assets based on content comparison results from find-duplicates.");
    _ = optionFrom(debugRemoveDuplicates, dbOption);
    _ = optionFrom(debugRemoveDuplicates, keyOption);
    _ = optionFrom(debugRemoveDuplicates, verboseOption);
    _ = optionFrom(debugRemoveDuplicates, yesOption);
    _ = optionFrom(debugRemoveDuplicates, cwdOption);
    _ = debugRemoveDuplicates
        .option("-i, --input <path>", "Input JSON file path from find-duplicates command (default: duplicates.json)", .{ .string = "duplicates.json" })
        .action(state, debugRemoveDuplicatesAction);

    const debugBuildSortIndex = debugCommand
        .command("build-sort-index", .{})
        .description("Deletes all sort index files and rebuilds them completely.");
    _ = optionFrom(debugBuildSortIndex, dbOption);
    _ = optionFrom(debugBuildSortIndex, keyOption);
    _ = optionFrom(debugBuildSortIndex, verboseOption);
    _ = optionFrom(debugBuildSortIndex, yesOption);
    _ = optionFrom(debugBuildSortIndex, cwdOption);
    _ = debugBuildSortIndex.action(state, debugBuildSortIndexAction);

    const debugBuildFilesTree = debugCommand
        .command("build-files-tree", .{})
        .description("Rebuild the files merkle tree (.db/files.dat) from actual files on storage (logical content hash/length/lastModified per file).");
    _ = optionFrom(debugBuildFilesTree, dbOption);
    _ = optionFrom(debugBuildFilesTree, keyOption);
    _ = optionFrom(debugBuildFilesTree, verboseOption);
    _ = optionFrom(debugBuildFilesTree, yesOption);
    _ = optionFrom(debugBuildFilesTree, cwdOption);
    _ = debugBuildFilesTree.action(state, debugBuildFilesTreeAction);

    _ = program
        .command("help [command]", .{})
        .description("Display help for command")
        .action(state, helpAction);

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

    const consolidateDefinition = program
        .command("consolidate", .{})
        .description("Joins this database to a remote one so the two can sync, creating the remote when it does not exist and recording it as the origin.")
        .argument("<remote>", "Path or URI of the remote database (a directory or an s3: location).");
    _ = optionFrom(consolidateDefinition, dbOption);
    _ = optionFrom(consolidateDefinition, keyOption);
    _ = optionFrom(consolidateDefinition, destKeyOption);
    _ = optionFrom(consolidateDefinition, verboseOption);
    _ = optionFrom(consolidateDefinition, yesOption);
    _ = optionFrom(consolidateDefinition, cwdOption);
    _ = optionFrom(consolidateDefinition, sessionIdOption);
    _ = consolidateDefinition
        .addHelpText(.after, try getCommandExamplesHelp(allocator, "consolidate"))
        .action(state, consolidateAction);

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

    const mcpDefinition = program
        .command("mcp", .{})
        .description("Start an MCP server (stdio transport). The MCP client chooses which database to open at runtime via list_databases / open_database.");
    _ = optionFrom(mcpDefinition, verboseOption);
    _ = optionFrom(mcpDefinition, yesOption);
    _ = optionFrom(mcpDefinition, cwdOption);
    _ = mcpDefinition.action(state, mcpAction);

    _ = program
        .command("news", .{})
        .description("Displays the latest update notification and all news items from the Photosphere feed.")
        .addHelpText(.after, try getCommandExamplesHelp(allocator, "news"))
        .action(state, newsAction);

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

    const removeOrphansDefinition = program
        .command("remove-orphans", .{})
        .description("Find and remove files that are no longer in the merkle tree.");
    _ = optionFrom(removeOrphansDefinition, dbOption);
    _ = optionFrom(removeOrphansDefinition, keyOption);
    _ = optionFrom(removeOrphansDefinition, verboseOption);
    _ = optionFrom(removeOrphansDefinition, yesOption);
    _ = optionFrom(removeOrphansDefinition, cwdOption);
    _ = removeOrphansDefinition
        .addHelpText(.after, try getCommandExamplesHelp(allocator, "remove-orphans"))
        .action(state, removeOrphansAction);

    const repairDefinition = program
        .command("repair", .{})
        .description("Repairs the integrity of the media file database by restoring files from a source database.");
    _ = optionFrom(repairDefinition, dbOption);
    _ = optionFrom(repairDefinition, sourceDbOption);
    _ = optionFrom(repairDefinition, keyOption);
    _ = repairDefinition.option("--sk, --source-key <keyfile>", "Path to source encryption key file", null);
    _ = optionFrom(repairDefinition, verboseOption);
    _ = optionFrom(repairDefinition, yesOption);
    _ = repairDefinition.option("--full", "Force full verification (bypass cached hash optimization)", .{ .boolean = false });
    _ = optionFrom(repairDefinition, cwdOption);
    _ = repairDefinition
        .addHelpText(.after, try getCommandExamplesHelp(allocator, "repair"))
        .action(state, repairAction);

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

    const syncDefinition = program
        .command("sync", .{})
        .description("Synchronize changes between two databases, once or by watching for more.");
    _ = optionFrom(syncDefinition, dbOption);
    _ = optionFrom(syncDefinition, destDbOption);
    _ = optionFrom(syncDefinition, keyOption);
    _ = optionFrom(syncDefinition, destKeyOption);
    _ = syncDefinition
        .option("--watch", "Keep syncing as the database changes, rather than syncing once and exiting.", .{ .boolean = false })
        .option("--interval <seconds>", "How long to wait between syncs when watching.", null);
    _ = optionFrom(syncDefinition, verboseOption);
    _ = optionFrom(syncDefinition, yesOption);
    _ = optionFrom(syncDefinition, cwdOption);
    _ = syncDefinition
        .addHelpText(.after, try getCommandExamplesHelp(allocator, "sync"))
        .action(state, syncAction);

    const toolsDefinition = program
        .command("tools", .{})
        .description("Checks for required media processing tools (ImageMagick, ffmpeg, ffprobe).");
    _ = optionFrom(toolsDefinition, yesOption);
    _ = toolsDefinition
        .addHelpText(.after, try getCommandExamplesHelp(allocator, "tools"))
        .action(state, toolsAction);

    const upgradeDefinition = program
        .command("upgrade", .{})
        .description("Upgrades a media file database to the latest version.");
    _ = optionFrom(upgradeDefinition, dbOption);
    _ = optionFrom(upgradeDefinition, keyOption);
    _ = optionFrom(upgradeDefinition, verboseOption);
    _ = optionFrom(upgradeDefinition, yesOption);
    _ = optionFrom(upgradeDefinition, cwdOption);
    _ = upgradeDefinition
        .addHelpText(.after, try getCommandExamplesHelp(allocator, "upgrade"))
        .action(state, upgradeAction);

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

    const encryptDefinition = program
        .command("encrypt", .{})
        .description("Encrypts the database in place (plain \u{2192} encrypted, re-encrypt with new key, or old-format \u{2192} new format).");
    _ = optionFrom(encryptDefinition, dbOption);
    _ = optionFrom(encryptDefinition, keyOption);
    _ = optionFrom(encryptDefinition, generateKeyOption);
    _ = optionFrom(encryptDefinition, yesOption);
    _ = optionFrom(encryptDefinition, cwdOption);
    _ = optionFrom(encryptDefinition, verboseOption);
    _ = encryptDefinition
        .addHelpText(.after, try getCommandExamplesHelp(allocator, "encrypt"))
        .action(state, encryptAction);

    const decryptDefinition = program
        .command("decrypt", .{})
        .description("Decrypts the encrypted database in place (removes encryption; deletes .db/encryption.pub).");
    _ = optionFrom(decryptDefinition, dbOption);
    _ = optionFrom(decryptDefinition, keyOption);
    _ = optionFrom(decryptDefinition, yesOption);
    _ = optionFrom(decryptDefinition, cwdOption);
    _ = optionFrom(decryptDefinition, verboseOption);
    _ = decryptDefinition
        .addHelpText(.after, try getCommandExamplesHelp(allocator, "decrypt"))
        .action(state, decryptAction);

    _ = program.addCommand(secretsCommand(allocator, state));
    _ = program.addCommand(dbsCommand(allocator, state));

    return program;
}

//
// The action of `secrets add` (`.action(secretsAdd)`): `run` calls the command.
//
fn secretsAddAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .secretsAdd = .{
            .yes = flagValue(options, "yes"),
            .name = textValue(options, "name"),
            .type = textValue(options, "type"),
            .value = textValue(options, "value"),
        },
    };
}

//
// The action of `secrets list` (`.action(secretsList)`): `run` calls the command.
//
fn secretsListAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = options;
    _ = command;
    state.outcome = .secretsList;
}

//
// The action of `secrets view` (`.action(secretsView)`): `run` calls the command.
//
fn secretsViewAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .secretsView = .{
            .yes = flagValue(options, "yes"),
            .name = textValue(options, "name"),
            .raw = flagValue(options, "raw"),
        },
    };
}

//
// The action of `secrets edit` (`.action(secretsEdit)`): `run` calls the command.
//
fn secretsEditAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .secretsEdit = .{
            .yes = flagValue(options, "yes"),
            .name = textValue(options, "name"),
            .newName = textValue(options, "newName"),
            .value = textValue(options, "value"),
            .valueFile = textValue(options, "valueFile"),
        },
    };
}

//
// The action of `secrets remove` (`.action(secretsRemove)`): `run` calls the command.
//
fn secretsRemoveAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .secretsRemove = .{
            .yes = flagValue(options, "yes"),
            .name = textValue(options, "name"),
        },
    };
}

//
// The action of `secrets clear` (`.action(secretsClear)`): `run` calls the command.
//
fn secretsClearAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .secretsClear = .{
            .yes = flagValue(options, "yes"),
        },
    };
}

//
// The action of `secrets import` (`.action(secretsImport)`): `run` calls the command.
//
fn secretsImportAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .secretsImport = .{
            .yes = flagValue(options, "yes"),
            .privateKey = textValue(options, "privateKey"),
        },
    };
}

//
// The action of `secrets send` (`.action(secretsSend)`): `run` calls the command.
//
fn secretsSendAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .secretsSend = .{
            .yes = flagValue(options, "yes"),
            .name = textValue(options, "name"),
            .code = textValue(options, "code"),
        },
    };
}

//
// The action of `secrets receive` (`.action(secretsReceive)`): `run` calls the command.
//
fn secretsReceiveAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .secretsReceive = .{
            .yes = flagValue(options, "yes"),
            .code = textValue(options, "code"),
        },
    };
}

//
// The `psi secrets` command group (secretsCommand in apps/cli/src/cmd/secrets.ts).
//
fn secretsCommand(allocator: std.mem.Allocator, state: *IProgramState) *Command {
    const cmd = Command.init(allocator, "secrets")
        .alias("sec")
        .alias("s")
        .description("Manage secrets stored in the Photosphere secrets store.");

    // psi secrets add
    _ = cmd.command("add", .{})
        .description("Interactively add a new secret.")
        .option("--yes", "Skip prompts", null)
        .option("--name <name>", "Secret name", null)
        .option("--type <type>", "Secret type", null)
        .option("--value <value>", "Secret value", null)
        .action(state, secretsAddAction);

    // psi secrets list
    _ = cmd.command("list", .{})
        .alias("l")
        .alias("ls")
        .description("List all secrets (values are masked).")
        .action(state, secretsListAction);

    // psi secrets view
    _ = cmd.command("view", .{})
        .alias("v")
        .description("Show the full value of a named secret.")
        .option("--yes", "Skip confirmation prompt", null)
        .option("--name <name>", "Secret name", null)
        .option("--raw", "Print only the raw value, with no labels or colouring, for capture by another program", null)
        .action(state, secretsViewAction);

    // psi secrets edit
    _ = cmd.command("edit", .{})
        .alias("e")
        .description("Edit an existing secret, field by field.")
        .option("--yes", "Skip prompts", null)
        .option("--name <name>", "Secret name to edit", null)
        .option("--new-name <name>", "New secret name", null)
        .option("--value <value>", "New value", null)
        .option("--value-file <path>", "Read new value from a file (for multiline values such as PEM keys)", null)
        .action(state, secretsEditAction);

    // psi secrets remove
    _ = cmd.command("remove", .{})
        .description("Remove a named secret.")
        .option("--yes", "Skip confirmation prompt", null)
        .option("--name <name>", "Secret name to remove", null)
        .action(state, secretsRemoveAction);

    // psi secrets clear
    _ = cmd.command("clear", .{})
        .description("Remove all secrets.")
        .option("--yes", "Skip confirmation prompt", null)
        .action(state, secretsClearAction);

    // psi secrets import
    _ = cmd.command("import", .{})
        .description("Import a PEM private key file as an encryption key.")
        .option("--yes", "Skip prompts", null)
        .option("--private-key <path>", "Path to private key file", null)
        .action(state, secretsImportAction);

    // psi secrets send
    _ = cmd.command("send", .{})
        .description("Send a secret to another device over the local network.")
        .option("--yes", "Skip confirmation prompts", null)
        .option("--name <name>", "Secret name to send", null)
        .option("--code <code>", "Use a specific pairing code instead of generating one (useful for scripted use)", null)
        .action(state, secretsSendAction);

    // psi secrets receive
    _ = cmd.command("receive", .{})
        .description("Receive a secret from another device over the local network.")
        .option("--yes", "Skip confirmation prompts and field editing", null)
        .option("--code <code>", "Pairing code shown on the sender (required with --yes)", null)
        .action(state, secretsReceiveAction);

    return cmd;
}

//
// The action of `dbs list` (`.action(dbsList)`): `run` calls the command.
//
fn dbsListAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = options;
    _ = command;
    state.outcome = .dbsList;
}

//
// The action of `dbs add` (`.action(dbsAdd)`): `run` calls the command.
//
fn dbsAddAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .dbsAdd = .{
            .yes = flagValue(options, "yes"),
            .name = textValue(options, "name"),
            .description = textValue(options, "description"),
            .path = textValue(options, "path"),
            .s3Cred = textValue(options, "s3Cred"),
            .encryptionKey = textValue(options, "encryptionKey"),
            .geocodingKey = textValue(options, "geocodingKey"),
        },
    };
}

//
// The action of `dbs view` (`.action(dbsView)`): `run` calls the command.
//
fn dbsViewAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .dbsView = .{
            .yes = flagValue(options, "yes"),
            .name = textValue(options, "name"),
            .path = textValue(options, "path"),
        },
    };
}

//
// The action of `dbs edit` (`.action(dbsEdit)`): `run` calls the command.
//
fn dbsEditAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .dbsEdit = .{
            .yes = flagValue(options, "yes"),
            .name = textValue(options, "name"),
            .newName = textValue(options, "newName"),
            .description = textValue(options, "description"),
            .path = textValue(options, "path"),
            .s3Cred = textValue(options, "s3Cred"),
            .encryptionKey = textValue(options, "encryptionKey"),
            .geocodingKey = textValue(options, "geocodingKey"),
        },
    };
}

//
// The action of `dbs remove` (`.action(dbsRemove)`): `run` calls the command.
//
fn dbsRemoveAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .dbsRemove = .{
            .yes = flagValue(options, "yes"),
            .name = textValue(options, "name"),
            .path = textValue(options, "path"),
        },
    };
}

//
// The action of `dbs clear` (`.action(dbsClear)`): `run` calls the command.
//
fn dbsClearAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .dbsClear = .{
            .yes = flagValue(options, "yes"),
        },
    };
}

//
// The action of `dbs send` (`.action(dbsSend)`): `run` calls the command.
//
fn dbsSendAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .dbsSend = .{
            .yes = flagValue(options, "yes"),
            .name = textValue(options, "name"),
            .path = textValue(options, "path"),
            .code = textValue(options, "code"),
        },
    };
}

//
// The action of `dbs receive` (`.action(dbsReceive)`): `run` calls the command.
//
fn dbsReceiveAction(state: *IProgramState, args: []const ArgumentValue, options: *const OptionValues, command: *Command) !void {
    _ = args;
    _ = command;
    state.outcome = .{
        .dbsReceive = .{
            .yes = flagValue(options, "yes"),
            .code = textValue(options, "code"),
        },
    };
}

//
// The `psi dbs` command group (dbsCommand in apps/cli/src/cmd/dbs.ts).
//
fn dbsCommand(allocator: std.mem.Allocator, state: *IProgramState) *Command {
    const cmd = Command.init(allocator, "dbs")
        .alias("d")
        .description("Manage the list of configured databases.");

    // psi dbs list
    _ = cmd.command("list", .{})
        .alias("l")
        .alias("ls")
        .description("List all configured databases.")
        .action(state, dbsListAction);

    // psi dbs add
    _ = cmd.command("add", .{})
        .description("Interactively add a new database to the list.")
        .option("--yes", "Skip prompts", null)
        .option("--name <name>", "Database name", null)
        .option("--description <desc>", "Database description", null)
        .option("--path <path>", "Database path", null)
        .option("--s3-cred <name>", "S3 credential secret name", null)
        .option("--encryption-key <name>", "Encryption key secret name", null)
        .option("--geocoding-key <name>", "Geocoding API key secret name", null)
        .action(state, dbsAddAction);

    // psi dbs view
    _ = cmd.command("view", .{})
        .alias("v")
        .description("Show all fields of a database entry.")
        .option("--yes", "Skip interactive selection (requires --name or --path)", null)
        .option("--name <name>", "Database name", null)
        .option("--path <path>", "Database path", null)
        .action(state, dbsViewAction);

    // psi dbs edit
    _ = cmd.command("edit", .{})
        .alias("e")
        .description("Edit fields of a database entry.")
        .option("--yes", "Skip prompts", null)
        .option("--name <name>", "Database name to edit", null)
        .option("--new-name <name>", "New database name", null)
        .option("--description <desc>", "New description", null)
        .option("--path <path>", "New database path", null)
        .option("--s3-cred <name>", "S3 credential secret name", null)
        .option("--encryption-key <name>", "Encryption key secret name", null)
        .option("--geocoding-key <name>", "Geocoding API key secret name", null)
        .action(state, dbsEditAction);

    // psi dbs remove
    _ = cmd.command("remove", .{})
        .description("Remove a database entry from the list.")
        .option("--yes", "Skip confirmation prompt", null)
        .option("--name <name>", "Database name", null)
        .option("--path <path>", "Database path", null)
        .action(state, dbsRemoveAction);

    // psi dbs clear
    _ = cmd.command("clear", .{})
        .description("Remove all database entries from the list.")
        .option("--yes", "Skip confirmation prompt", null)
        .action(state, dbsClearAction);

    // psi dbs send
    _ = cmd.command("send", .{})
        .description("Send a database config (with secrets) to another device over the local network.")
        .option("--yes", "Skip confirmation prompts and field editing", null)
        .option("--name <name>", "Database name", null)
        .option("--path <path>", "Database path", null)
        .option("--code <code>", "Use a specific pairing code instead of generating one (useful for scripted use)", null)
        .action(state, dbsSendAction);

    // psi dbs receive
    _ = cmd.command("receive", .{})
        .description("Receive a database config (with secrets) from another device over the local network.")
        .option("--yes", "Skip confirmation prompts and field editing", null)
        .option("--code <code>", "Pairing code shown on the other device (required with --yes)", null)
        .action(state, dbsReceiveAction);

    return cmd;
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
        if (err == error.Exit) {
            return .{ .processExit = program.getCommanderError().?.exitCode };
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
            // The error rethrown is commander's CommanderError, which shows under that name.
            utils.errors.recordError("CommanderError", "{s}", .{failure.message});
            return error.Thrown;
        },
        .add => |parsed| {
            var options = parsed.options;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try addCommand(allocator, io, context, parsed.paths, &options);
        },
        .check => |parsed| {
            var options = parsed.options;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try checkCommand(allocator, io, context, parsed.paths, &options);
        },
        .repair => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try repairCommand(allocator, io, context, &options);
        },
        .findOrphans => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try findOrphansCommand(allocator, io, context, &options);
        },
        .sync => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try syncCommand(allocator, io, context, &options);
        },
        .consolidate => |parsed| {
            var options = parsed.options;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try consolidateCommand(allocator, io, context, parsed.remote, &options);
        },
        .encrypt => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try encryptCommand(allocator, io, context, &options);
        },
        .bug => |parsed| {
            // The preAction hook skips the notifications for bug.
            const options = parsed;
            try bugReportCommand(allocator, io, &options);
        },
        .news => {
            // The preAction hook skips the notifications for news.
            try newsCommand(allocator, io);
        },
        .decrypt => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try decryptCommand(allocator, io, context, &options);
        },
        .debugMerkleTree => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try debugMerkleTreeCommand(allocator, io, context, &options);
        },
        .debugFindCollisions => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try debugFindCollisionsCommand(allocator, io, context, &options);
        },
        .debugFindDuplicates => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try debugFindDuplicatesCommand(allocator, io, context, &options);
        },
        .debugRemoveDuplicates => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try debugRemoveDuplicatesCommand(allocator, io, context, &options);
        },
        .debugBuildSortIndex => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options);
            try debugBuildSortIndexCommand(allocator, io, context, &options);
        },
        .debugBuildFilesTree => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options);
            try debugBuildFilesTreeCommand(allocator, io, context, &options);
        },
        .hash => |parsed| {
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try hashCommand(allocator, io, parsed.filePath, &parsed.options);
        },
        .tools => |parsed| {
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try toolsCommand(allocator, io, &parsed);
        },
        .hashCacheShow => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try hashCacheCommand(allocator, io, context, &options);
        },
        .hashCacheClear => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try clearCacheCommand(allocator, io, context, &options);
        },
        .hashCacheHashFile => |file| {
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try hash_cache_tools.hashFileCommand(allocator, io, file);
        },
        .hashCacheAdd => |parsed| {
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try hash_cache_tools.hashCacheAddCommand(allocator, io, parsed.file, parsed.options);
        },
        .hashCacheSet => |parsed| {
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try hash_cache_tools.hashCacheSetCommand(allocator, io, parsed.key, parsed.hash, parsed.length, parsed.options);
        },
        .hashCacheSetSource => |parsed| {
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try hash_cache_tools.hashCacheSetSourceCommand(allocator, io, parsed.key, parsed.hash, parsed.length, parsed.options);
        },
        .hashCacheGet => |parsed| {
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try hash_cache_tools.hashCacheGetCommand(allocator, io, parsed.key, parsed.options);
        },
        .hashCacheGetAssetId => |parsed| {
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try hash_cache_tools.hashCacheGetAssetIdCommand(allocator, io, parsed.key, parsed.options);
        },
        .hashCacheRemove => |parsed| {
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try hash_cache_tools.hashCacheRemoveCommand(allocator, io, parsed.key, parsed.options);
        },
        .hashCacheList => |parsed| {
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try hash_cache_tools.hashCacheListCommand(allocator, io, parsed);
        },
        .hashCacheCount => |parsed| {
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try hash_cache_tools.hashCacheCountCommand(allocator, io, parsed);
        },
        .hashCacheDir => |parsed| {
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try hash_cache_tools.hashCacheDirCommand(allocator, io, parsed);
        },
        .upgrade => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try upgradeCommand(allocator, io, context, &options);
        },
        .removeOrphans => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try removeOrphansCommand(allocator, io, context, &options);
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
        .examples => {
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try examplesCommand(allocator);
        },
        .help => |commandName| {
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            // The help ends the parse the way it does in index.ts: main() exits with 0 for the help of the program
            // and the commands, and the secrets and dbs groups call process.exit themselves.
            const helpError = helpCommand(program, commandName);
            if (helpError != error.CommanderError and helpError != error.Exit) {
                return helpError;
            }
            exit(io, program.getCommanderError().?.exitCode);
        },
        .secretsAdd => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try secrets.secretsAdd(allocator, io, &options);
        },
        .secretsList => {
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try secrets.secretsList(allocator, io);
        },
        .secretsView => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try secrets.secretsView(allocator, io, &options);
        },
        .secretsEdit => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try secrets.secretsEdit(allocator, io, &options);
        },
        .secretsRemove => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try secrets.secretsRemove(allocator, io, &options);
        },
        .secretsClear => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try secrets.secretsClear(allocator, io, &options);
        },
        .secretsImport => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try secrets.secretsImport(allocator, io, &options);
        },
        .secretsSend => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try secrets.secretsSend(allocator, io, &options);
        },
        .secretsReceive => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try secrets.secretsReceive(allocator, io, &options);
        },
        .dbsList => {
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try dbs.dbsList(allocator, io);
        },
        .dbsAdd => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try dbs.dbsAdd(allocator, io, &options);
        },
        .dbsView => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try dbs.dbsView(allocator, io, &options);
        },
        .dbsEdit => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try dbs.dbsEdit(allocator, io, &options);
        },
        .dbsRemove => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try dbs.dbsRemove(allocator, io, &options);
        },
        .dbsClear => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try dbs.dbsClear(allocator, io, &options);
        },
        .dbsSend => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try dbs.dbsSend(allocator, io, &options);
        },
        .dbsReceive => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            try dbs.dbsReceive(allocator, io, &options);
        },
        .mcp => |parsed| {
            var options = parsed;
            if (state.notificationsQuiet) |quiet| {
                try print_notifications.printNotifications(allocator, io, quiet);
            }
            const context = try initContext(allocator, io, options.base);
            try mcpCommand(allocator, io, context, &options);
        },
        .processExit => |exitCode| {
            exit(io, exitCode);
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
