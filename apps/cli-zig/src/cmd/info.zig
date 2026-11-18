const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const tools = @import("tools-zig");
const bdb = @import("bdb-zig");
const serialization = @import("serialization-zig");
const pc = @import("../lib/picocolors.zig");
const init_cmd = @import("../lib/init-cmd.zig");
const terminal_utils = @import("../lib/terminal-utils.zig");
const format = @import("../lib/format.zig");
const exit = node_utils.termination.exit;
const InProcessRunner = node_utils.in_process_tools.InProcessRunner;
const loadDatabase = init_cmd.loadDatabase;
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;
const ICommandContext = init_cmd.ICommandContext;
const clearProgressMessage = terminal_utils.clearProgressMessage;
const writeProgress = terminal_utils.writeProgress;
const scanPaths = node_api.file_scanner.scanPaths;
const IFileStat = node_api.file_scanner.IFileStat;
const FileScannedResult = node_api.file_scanner.FileScannedResult;
const ScannerState = node_api.file_scanner.ScannerState;
const computeHash = node_api.hash.computeHash;
const toLocaleString = node_api.verify_worker.toLocaleString;
const mime = node_api.mime.mime;
const getFileInfo = tools.getFileInfo;
const pathExists = node_utils.fs.pathExists;
const AssetInfo = tools.types.AssetInfo;
const js_value = bdb.js_value;
const BsonValue = serialization.bson.BsonValue;

//
// An asset record from the metadata collection.
//
const IAsset = bdb.collection.IRecord;

//
// Options of the info command.
// The base options (which hold verbose, tools and yes) are in `base`.
//
pub const IInfoCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},
};

//
// The kind of an info input.
//
const InputKind = enum {
    path,
    assetId,
    hash,
};

//
// Tests `/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i`.
//
fn isUuid(input: []const u8) bool {
    if (input.len != 36) {
        return false;
    }
    for (input, 0..) |character, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (character != '-') {
                return false;
            }
        }
        else if (!std.ascii.isHex(character)) {
            return false;
        }
    }
    return true;
}

//
// Tests `/^[0-9a-f]{64}$/i`.
//
fn isHash(input: []const u8) bool {
    if (input.len != 64) {
        return false;
    }
    for (input) |character| {
        if (!std.ascii.isHex(character)) {
            return false;
        }
    }
    return true;
}

//
// Classifies an input as a file path, an asset ID or a hash.
//
pub fn classifyInput(input: []const u8) InputKind {
    if (isUuid(input)) {
        return .assetId;
    }
    if (isHash(input)) {
        return .hash;
    }
    return .path;
}

//
// What is known about one input.
//
const FileAnalysis = struct {
    // The path of the file.
    path: []const u8,

    // The size and modified time of the file.
    fileStat: ?IFileStat = null,

    // The media information of the file.
    assetInfo: ?AssetInfo = null,

    // The hash of the file, as hex.
    hash: ?[]const u8 = null,

    // The error that stopped the analysis.
    @"error": ?[]const u8 = null,

    // The path shown for the file.
    logicalPath: []const u8,

    // Set when result is from database lookup
    asset: ?IAsset = null,
};

//
// The state of the scan callbacks.
//
const ScanState = struct {
    // Allocates the results.
    allocator: std.mem.Allocator,

    // The io of the command.
    io: std.Io,

    // Runs the ImageMagick and FFmpeg built into the program, which read the media information.
    toolRunner: InProcessRunner,

    // The results collected so far.
    results: *std.ArrayList(FileAnalysis),

    // How many files have been analyzed.
    fileCount: usize,
};

//
// Analyzes each scanned file.
//
fn visitScannedFile(context: ?*anyopaque, log: ILog, fileResult: FileScannedResult) anyerror!void {
    const state: *ScanState = @ptrCast(@alignCast(context.?));
    const analysis = analyzeFile(state.allocator, state.io, log, state.toolRunner, fileResult.filePath, fileResult.contentType, fileResult.fileStat, fileResult.logicalPath) catch |err| {
        try state.results.append(state.allocator, .{
            .path = fileResult.filePath,
            .fileStat = fileResult.fileStat,
            .logicalPath = fileResult.logicalPath,
            .@"error" = utils.errors.errorMessage(err),
        });
        state.fileCount += 1;
        return;
    };
    try state.results.append(state.allocator, analysis);
    state.fileCount += 1;
}

//
// Shows scan progress.
//
fn scanProgress(context: ?*anyopaque, log: ILog, currentlyScanning: ?[]const u8, scannerState: *const ScannerState) void {
    _ = scannerState;
    const state: *ScanState = @ptrCast(@alignCast(context.?));
    const message = progressMessage(state.allocator, state.fileCount, currentlyScanning) catch return;
    writeProgress(log, message);
}

//
// Builds the progress message of the scan.
//
fn progressMessage(allocator: std.mem.Allocator, fileCount: usize, currentlyScanning: ?[]const u8) ![]const u8 {
    var message = try std.fmt.allocPrint(allocator, "Analyzed: {s} files", .{try pc.green(allocator, try std.fmt.allocPrint(allocator, "{d}", .{fileCount}))});
    if (currentlyScanning) |scanning| {
        if (scanning.len > 0) {
            message = try std.fmt.allocPrint(allocator, "{s} | Scanning {s}", .{ message, try pc.cyan(allocator, scanning) });
        }
    }
    return std.fmt.allocPrint(allocator, "{s} | Abort with Ctrl-C", .{message});
}

//
// Command that displays detailed information about media files, or about assets in the database by ID or hash.
//
pub fn infoCommand(allocator: std.mem.Allocator, io: std.Io, log: ILog, context: ICommandContext, inputs: []const []const u8, options: *IInfoCommandOptions) !void {
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionTempDir = context.sessionTempDir;
    const sessionId = context.sessionId;

    var pathInputs: std.ArrayList([]const u8) = .empty;
    var dbInputs: std.ArrayList([]const u8) = .empty;
    for (inputs) |input| {
        switch (classifyInput(input)) {
            .path => try pathInputs.append(allocator, input),
            .assetId, .hash => try dbInputs.append(allocator, input),
        }
    }

    var results: std.ArrayList(FileAnalysis) = .empty;

    //
    // A path that does not exist stops the command with exit code 1, as `psi hash` does, so a
    // mistyped name is never reported as an empty success.
    //
    for (pathInputs.items) |input| {
        if (!pathExists(io, input)) {
            log.err(try pc.red(allocator, try std.fmt.allocPrint(allocator, "File not found: {s}", .{input})));
            exit(io, log, 1);
        }
    }

    if (pathInputs.items.len > 0) {
        writeProgress(log, "Searching for files...");
        var state: ScanState = .{
            .allocator = allocator,
            .io = io,
            .toolRunner = context.toolRunner,
            .results = &results,
            .fileCount = 0,
        };
        try scanPaths(
            allocator,
            io,
            log,
            pathInputs.items,
            .{ .context = &state, .function = visitScannedFile },
            .{ .context = &state, .function = scanProgress },
            .{ .ignorePatterns = &.{".db"} },
            sessionTempDir,
            uuidGenerator,
        );
        clearProgressMessage(log);
    }

    if (dbInputs.items.len > 0) {
        const loaded = try loadDatabase(allocator, io, log, options.base.db, &options.base, uuidGenerator, timestampProvider, sessionId, false);
        const metadataCollection = try loaded.bsonDatabase.collection("metadata");
        for (dbInputs.items) |input| {
            const kind = classifyInput(input);
            if (kind == .assetId) {
                if (try metadataCollection.getOne(io, log, input)) |asset| {
                    try results.append(allocator, try assetToFileAnalysis(allocator, asset, input));
                }
                else {
                    try results.append(allocator, .{
                        .path = "",
                        .logicalPath = try std.fmt.allocPrint(allocator, "Asset ID: {s}", .{input}),
                        .@"error" = "Asset not found in database",
                    });
                }
            }
            else {
                const assets = try (try metadataCollection.sortIndex("hash", .asc)).findByValue(io, log, .{ .string = input }, null);
                if (assets.len == 0) {
                    try results.append(allocator, .{
                        .path = "",
                        .logicalPath = try std.fmt.allocPrint(allocator, "Hash: {s}", .{input}),
                        .@"error" = "No asset with this hash found in database",
                    });
                }
                else {
                    const total = assets.len;
                    for (assets, 0..) |asset, index| {
                        const label = if (total > 1)
                            try std.fmt.allocPrint(allocator, "Hash: {s} ({d} of {d})", .{ input, index + 1, total })
                        else
                            try std.fmt.allocPrint(allocator, "Hash: {s}", .{input});
                        try results.append(allocator, try assetToFileAnalysis(allocator, asset, label));
                    }
                }
            }
        }
    }

    const totalCount = results.items.len;
    log.info(try std.fmt.allocPrint(allocator, "\nInfo for {d} item(s):\n", .{totalCount}));

    for (results.items) |result| {
        try displayFileInfo(log, allocator, result, options);
        log.info("");
    }

    log.info(try pc.green(allocator, try std.fmt.allocPrint(allocator, "\nDisplayed info for {d} item(s).", .{totalCount})));
    log.info("");

    exit(io, log, 0);
}

//
// Gets a field of an asset, undefined when it is missing.
//
fn field(asset: IAsset, name: []const u8) BsonValue {
    return asset.get(name) orelse .undefined;
}

//
// Whether a field value counts as set: not undefined, null, false, zero, NaN or an empty string.
//
fn isTruthy(value: BsonValue) bool {
    return switch (value) {
        .number, .double => |number| number != 0 and !std.math.isNan(number),
        .int32 => |number| number != 0,
        .int64 => |number| number != 0,
        .string => |text| text.len > 0,
        .undefined, .null => false,
        .boolean => |boolean| boolean,
        else => true,
    };
}

//
// Converts an asset found in the database to an analysis.
//
fn assetToFileAnalysis(allocator: std.mem.Allocator, asset: IAsset, logicalPath: []const u8) !FileAnalysis {
    const origPath = field(asset, "origPath");
    const pathValue = if (origPath != .undefined and origPath != .null) origPath else field(asset, "origFileName");
    const hash = field(asset, "hash");
    return .{
        .path = try js_value.toString(allocator, pathValue),
        .logicalPath = logicalPath,
        .hash = if (hash == .undefined) null else try js_value.toString(allocator, hash),
        .asset = asset,
    };
}

//
// Hashes a file and reads its media information with the tools toolRunner runs.
//
fn analyzeFile(allocator: std.mem.Allocator, io: std.Io, log: ILog, toolRunner: InProcessRunner, filePath: []const u8, contentType: []const u8, fileInfo: IFileStat, logicalPath: []const u8) !FileAnalysis {
    // filePath is either the temporary unpacked file path or the original source file path
    var fileAnalysis: FileAnalysis = .{
        .path = filePath,
        .fileStat = fileInfo,
        .logicalPath = logicalPath, // Include logical path if provided (shows location in zip files)
    };

    // Calculate file hash
    if (hashFile(io, filePath)) |hashBuffer| {
        fileAnalysis.hash = try std.fmt.allocPrint(allocator, "{x}", .{&hashBuffer});
    }
    else |err| {
        log.verbose(try std.fmt.allocPrint(allocator, "Failed to calculate hash for {s}: {s}", .{ filePath, try utils.errors.errorToString(allocator, err) }));
    }

    // Analyze file content using the unified getFileInfo function
    // Files are already unpacked, so we can use the file path directly
    if (getFileInfo(allocator, io, log, toolRunner, filePath, contentType)) |maybeAssetInfo| {
        if (maybeAssetInfo) |assetInfo| {
            fileAnalysis.assetInfo = assetInfo;
        }
    }
    else |err| {
        fileAnalysis.@"error" = try std.fmt.allocPrint(allocator, "Failed to analyze file: {s}", .{try utils.errors.errorToString(allocator, err)});
    }

    return fileAnalysis;
}

//
// Hashes a file's contents.
//
fn hashFile(io: std.Io, filePath: []const u8) ![32]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, filePath, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return computeHash(&reader.interface);
}

//
// Displays the information about one input.
//
fn displayFileInfo(log: ILog, allocator: std.mem.Allocator, analysis: FileAnalysis, options: *IInfoCommandOptions) !void {
    _ = options;

    log.info(try pc.bold(allocator, try pc.blue(allocator, try std.fmt.allocPrint(allocator, "\u{1F4C1} {s}", .{analysis.logicalPath}))));

    if (analysis.@"error") |message| {
        if (message.len > 0) {
            log.info(try std.fmt.allocPrint(allocator, "   {s}", .{try pc.red(allocator, try std.fmt.allocPrint(allocator, "Error: {s}", .{message}))}));
            return;
        }
    }

    if (analysis.asset) |asset| {
        try displayAssetInfo(log, allocator, asset);
        return;
    }

    const fileInfo = analysis.fileStat orelse {
        return;
    };

    const mimeType = if (fileInfo.contentType != null and fileInfo.contentType.?.len > 0)
        fileInfo.contentType.?
    else
        (try (try mime()).getType(allocator, analysis.path)) orelse "application/octet-stream";
    try displayField(log, allocator, "Type", mimeType);
    if (analysis.hash) |hash| {
        if (hash.len > 0) {
            try displayField(log, allocator, "Hash", hash);
        }
    }
    try displayField(log, allocator, "Size", try format.formatBytes(allocator, @floatFromInt(fileInfo.length), format.defaultFormatBytesOptions));
    try displayField(log, allocator, "Modified", try toLocaleString(allocator, fileInfo.lastModified));
    if (analysis.assetInfo) |assetInfo| {

        //
        // The date the photo or video was taken, from its EXIF or format tags, which getFileInfo reads
        // into createdAt. It is shown as well as the modified time because a copied file has a new modified
        // time but keeps the date it was taken. A file with no date, or one that does not parse (NaN),
        // shows no line.
        //
        if (assetInfo.createdAt) |createdAt| {
            if (!std.math.isNan(createdAt)) {
                try displayField(log, allocator, "Photo date", try toLocaleString(allocator, @intFromFloat(createdAt)));
            }
        }
        try displayField(log, allocator, "Dimensions", try std.fmt.allocPrint(allocator, "{s} \u{00D7} {s}", .{
            try js_value.toString(allocator, .{ .number = assetInfo.dimensions.width }),
            try js_value.toString(allocator, .{ .number = assetInfo.dimensions.height }),
        }));
    }
    if (analysis.@"error") |message| {
        if (message.len > 0) {
            log.info(try std.fmt.allocPrint(allocator, "   {s}", .{try pc.yellow(allocator, try std.fmt.allocPrint(allocator, "Analysis Error: {s}", .{message}))}));
        }
    }
}

//
// Prints one "label: value" line of an info block, indented under the block's heading, with the
// value starting in the same column on every line so the block reads as a table. The column fits
// the longest label, "Original file:" and "Original path:", with one space after it.
//
fn displayField(log: ILog, allocator: std.mem.Allocator, label: []const u8, value: []const u8) !void {
    const labelWithColon = try std.mem.concat(allocator, u8, &.{ label, ":" });
    std.debug.assert(labelWithColon.len < 15);
    log.info(try std.fmt.allocPrint(allocator, "   {s: <15}{s}", .{ labelWithColon, value }));
}

//
// Displays an asset found in the database.
//
fn displayAssetInfo(log: ILog, allocator: std.mem.Allocator, asset: IAsset) !void {
    try displayField(log, allocator, "Asset ID", try js_value.toString(allocator, field(asset, "_id")));
    try displayField(log, allocator, "Original file", try js_value.toString(allocator, field(asset, "origFileName")));
    if (isTruthy(field(asset, "origPath"))) {
        try displayField(log, allocator, "Original path", try js_value.toString(allocator, field(asset, "origPath")));
    }
    try displayField(log, allocator, "Type", try js_value.toString(allocator, field(asset, "contentType")));
    try displayField(log, allocator, "Hash", try js_value.toString(allocator, field(asset, "hash")));
    try displayField(log, allocator, "Dimensions", try std.fmt.allocPrint(allocator, "{s} \u{00D7} {s}", .{ try js_value.toString(allocator, field(asset, "width")), try js_value.toString(allocator, field(asset, "height")) }));
    try displayField(log, allocator, "File date", try js_value.toString(allocator, field(asset, "fileDate")));
    if (isTruthy(field(asset, "photoDate"))) {
        try displayField(log, allocator, "Photo date", try js_value.toString(allocator, field(asset, "photoDate")));
    }
    try displayField(log, allocator, "Upload date", try js_value.toString(allocator, field(asset, "uploadDate")));
    if (field(asset, "duration") != .undefined) {
        try displayField(log, allocator, "Duration", try std.fmt.allocPrint(allocator, "{s}s", .{try js_value.toString(allocator, field(asset, "duration"))}));
    }
    if (isTruthy(field(asset, "location"))) {
        try displayField(log, allocator, "Location", try js_value.toString(allocator, field(asset, "location")));
    }
    const coordinates = field(asset, "coordinates");
    if (isTruthy(coordinates)) {
        const lat = if (coordinates == .document) (coordinates.document.get("lat") orelse BsonValue.undefined) else BsonValue.undefined;
        const lng = if (coordinates == .document) (coordinates.document.get("lng") orelse BsonValue.undefined) else BsonValue.undefined;
        try displayField(log, allocator, "Coordinates", try std.fmt.allocPrint(allocator, "{s}, {s}", .{ try js_value.toString(allocator, lat), try js_value.toString(allocator, lng) }));
    }
    const labels = field(asset, "labels");
    if (labels == .array and labels.array.len > 0) {
        var joined: std.ArrayList(u8) = .empty;
        for (labels.array, 0..) |label, index| {
            if (index > 0) {
                try joined.appendSlice(allocator, ", ");
            }
            if (label != .undefined and label != .null) {
                try joined.appendSlice(allocator, try js_value.toString(allocator, label));
            }
        }
        try displayField(log, allocator, "Labels", joined.items);
    }
    if (isTruthy(field(asset, "description"))) {
        try displayField(log, allocator, "Description", try js_value.toString(allocator, field(asset, "description")));
    }
}
