const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const api = @import("api-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const bdb = @import("bdb-zig");
const pc = @import("../lib/picocolors.zig");
const init_cmd = @import("../lib/init-cmd.zig");
const directory_picker = @import("../lib/directory-picker.zig");
const terminal_utils = @import("../lib/terminal-utils.zig");
const log = &utils.log.log;
const exit = node_utils.termination.exit;
const loadDatabase = init_cmd.loadDatabase;
const jsNumber = init_cmd.jsNumber;
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;
const ICommandContext = init_cmd.ICommandContext;
const getDirectoryForCommand = directory_picker.getDirectoryForCommand;
const clearProgressMessage = terminal_utils.clearProgressMessage;
const writeProgress = terminal_utils.writeProgress;
const compareTrees = merkle_tree_zig.compare.compareTrees;
const loadDatabaseConfig = api.database_config.loadDatabaseConfig;
const loadMerkleTree = node_api.tree.loadMerkleTree;
const js_value = bdb.js_value;

//
// Options of the compare command (TypeScript: ICompareCommandOptions extends IBaseCommandOptions).
// The base options (which hold the source database directory, db) are in `base`.
//
pub const ICompareCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},

    //
    // Destination database directory.
    //
    dest: ?[]const u8 = null,

    //
    // Path to destination encryption key file.
    //
    destKey: ?[]const u8 = null,

    //
    // Show all differences without truncation.
    //
    full: ?bool = null,

    //
    // Maximum number of items to show in each category.
    // (Zig: the text of the option, which commander passes through without parsing it.)
    //
    max: ?[]const u8 = null,
};

//
// Writes each comparison progress message (TypeScript: `(progress) => { writeProgress(`🔍 Comparing | ${progress}`); }`).
//
fn onProgress(context: ?*anyopaque, progress: []const u8) void {
    _ = context;
    var buffer: [4096]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "\u{1F50D} Comparing | {s}", .{progress}) catch return;
    writeProgress(message);
}

//
// Gets `config?.origin` (null when the config or its origin is missing, or the origin is not a string).
//
fn configOrigin(config: ?std.json.Value) ?[]const u8 {
    const value = config orelse return null;
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const origin = object.get("origin") orelse return null;
    return switch (origin) {
        .string => |text| text,
        else => null,
    };
}

//
// The end index of `files.slice(0, maxItems)` for a JavaScript number: NaN is 0, a negative end counts back from
// the length, and the end is clamped to the length.
//
fn sliceEnd(length: usize, maxItems: f64) usize {
    if (std.math.isNan(maxItems)) {
        return 0;
    }
    const lengthValue: f64 = @floatFromInt(length);
    const end = @trunc(maxItems);
    if (end < 0) {
        return @intFromFloat(@max(lengthValue + end, 0));
    }
    return @intFromFloat(@min(end, lengthValue));
}

//
// Lists the files of one category of differences.
//
fn showFiles(allocator: std.mem.Allocator, files: []const []const u8, marker: []const u8, showFull: bool, maxItems: f64) !void {
    const filesToShow = if (showFull) files else files[0..sliceEnd(files.len, maxItems)];
    for (filesToShow) |file| {
        log.info(try std.fmt.allocPrint(allocator, "  {s} {s}", .{ marker, file }));
    }
    const length: f64 = @floatFromInt(files.len);
    if (!showFull and length > maxItems) {
        log.info(try std.fmt.allocPrint(allocator, "  ... and {s} more", .{try js_value.toString(allocator, .{ .number = length - maxItems })}));
    }
    log.info("");
}

//
// Command that compares two asset databases by analyzing their Merkle trees.
//
pub fn compareCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, options: *ICompareCommandOptions) !void {
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionId = context.sessionId;

    const nonInteractive = options.base.yes orelse false;
    const cwd = if (options.base.cwd != null and options.base.cwd.?.len > 0) options.base.cwd.? else try std.process.currentPathAlloc(io, allocator);

    var srcDir = options.base.db;
    if (srcDir == null) {
        srcDir = try getDirectoryForCommand(allocator, io, .existing, nonInteractive, cwd);
    }

    const src = try loadDatabase(allocator, io, srcDir, &options.base, uuidGenerator, timestampProvider, sessionId, false);
    const srcAssetStorage = src.assetStorage;
    const srcRawAssetStorage = src.rawAssetStorage;
    const srcDirResolved = src.databaseDir;

    var destDir = options.dest;
    if (destDir == null) {
        const config = try loadDatabaseConfig(allocator, io, srcRawAssetStorage);
        destDir = configOrigin(config);
        if (destDir == null) {
            destDir = try getDirectoryForCommand(allocator, io, .existing, nonInteractive, cwd);
        }
    }

    // Load destination database
    var destOptions = options.base;
    destOptions.db = destDir;
    destOptions.key = options.destKey;
    const dest = try loadDatabase(allocator, io, destDir, &destOptions, uuidGenerator, timestampProvider, sessionId, false);
    const destAssetStorage = dest.assetStorage;
    const destDirResolved = dest.databaseDir;

    log.info("");
    log.info("Comparing two databases:");
    log.info(try std.fmt.allocPrint(allocator, "  Source:         {s}", .{try pc.cyan(allocator, srcDirResolved)}));
    log.info(try std.fmt.allocPrint(allocator, "  Destination:    {s}", .{try pc.cyan(allocator, destDirResolved)}));
    log.info("");

    // Load merkle trees from the databases
    const srcMerkleTree = try loadMerkleTree(allocator, io, srcAssetStorage) orelse {
        clearProgressMessage();
        log.info(try pc.red(allocator, "Error: Failed to load source database merkle tree"));
        exit(io, 1);
    };

    const destMerkleTree = try loadMerkleTree(allocator, io, destAssetStorage) orelse {
        clearProgressMessage();
        log.info(try pc.red(allocator, "Error: Failed to load destination database merkle tree"));
        exit(io, 1);
    };

    // Fast path: Compare root hashes first
    if (std.mem.eql(u8, srcMerkleTree.merkle.?.hash, destMerkleTree.merkle.?.hash)) {
        log.info("");
        log.info(try pc.bold(allocator, try pc.blue(allocator, "\u{1F4CA} Comparison Results")));
        log.info("");

        log.info(try pc.green(allocator, "No differences detected"));
        exit(io, 0);
    }

    writeProgress("Comparing trees...");

    const compareResult = try compareTrees(allocator, &srcMerkleTree, &destMerkleTree, .{ .context = null, .function = onProgress });

    clearProgressMessage();

    log.info("");
    log.info(try pc.bold(allocator, try pc.blue(allocator, "\u{1F4CA} Comparison Results")));
    log.info("");

    const totalDifferences =
        compareResult.onlyInA.len +
        compareResult.onlyInB.len +
        compareResult.modified.len;

    var summaryParts: std.ArrayList([]const u8) = .empty;
    if (compareResult.onlyInA.len > 0) {
        try summaryParts.append(allocator, try std.fmt.allocPrint(allocator, "{d} files only in source", .{compareResult.onlyInA.len}));
    }
    if (compareResult.onlyInB.len > 0) {
        try summaryParts.append(allocator, try std.fmt.allocPrint(allocator, "{d} files only in destination", .{compareResult.onlyInB.len}));
    }
    if (compareResult.modified.len > 0) {
        try summaryParts.append(allocator, try std.fmt.allocPrint(allocator, "{d} modified files", .{compareResult.modified.len}));
    }

    log.info(try pc.yellow(allocator, try std.fmt.allocPrint(allocator, "Found differences: {s}", .{try std.mem.join(allocator, ", ", summaryParts.items)})));
    log.info("");

    const showFull = options.full orelse false;

    // `options.max || 10`: the text as a number, 10 when it is missing or empty.
    const maxItems: f64 = if (options.max != null and options.max.?.len > 0) jsNumber(options.max.?) else 10;

    // Files only in source
    if (compareResult.onlyInA.len > 0) {
        log.info(try pc.cyan(allocator, "Files only in source:"));
        try showFiles(allocator, compareResult.onlyInA, try pc.cyan(allocator, "+"), showFull, maxItems);
    }

    // Files only in destination
    if (compareResult.onlyInB.len > 0) {
        log.info(try pc.magenta(allocator, "Files only in destination:"));
        try showFiles(allocator, compareResult.onlyInB, try pc.magenta(allocator, "+"), showFull, maxItems);
    }

    // Modified files
    if (compareResult.modified.len > 0) {
        log.info(try pc.yellow(allocator, "Modified files:"));
        try showFiles(allocator, compareResult.modified, try pc.yellow(allocator, "\u{25CF}"), showFull, maxItems);
    }

    log.info(try pc.yellow(allocator, try std.fmt.allocPrint(allocator, "\u{26A0}\u{FE0F} Databases have {d} differences", .{totalDifferences})));
    exit(io, 0);
}
