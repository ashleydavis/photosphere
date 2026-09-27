const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const bdb = @import("bdb-zig");
const pc = @import("../lib/picocolors.zig");
const init_cmd = @import("../lib/init-cmd.zig");
const log = &utils.log.log;
const exit = node_utils.termination.exit;
const ensureDir = node_utils.fs.ensureDir;
const path = node_utils.path;
const openLazyOriginStorage = node_api.media_file_database.openLazyOriginStorage;
const loadDatabase = init_cmd.loadDatabase;
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;
const ICommandContext = init_cmd.ICommandContext;
const js_value = bdb.js_value;
const IStorage = @import("storage-zig").storage.IStorage;

//
// The versions of an asset that can be exported.
//
pub const AssetType = enum {
    original,
    display,
    thumb,
};

//
// Options of the export command (TypeScript: IExportCommandOptions extends IBaseCommandOptions).
// The base options are in `base`.
//
pub const IExportCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},

    //
    // Type of asset to export (original, display, thumb).
    // (Zig: the text of the option, because commander passes any text through.)
    //
    type: ?[]const u8 = null,
};

//
// Construct the storage path based on asset type.
//
// Separated by "/", the way every other caller writes it (asset-query.ts, upload-asset.worker.ts,
// repair.ts, list.ts). A storage path is not a filesystem path, so path.join is wrong: on Windows
// it returned "asset\<id>" while the object had been written at "asset/<id>", so exporting out of
// S3 looked for a key that does not exist. On Linux and macOS path.join happens to produce "/",
// which is why this only ever failed on Windows.
// (Zig: a type that is not one of the three is `default`, the original.)
//
fn getAssetStoragePath(allocator: std.mem.Allocator, assetId: []const u8, assetType: []const u8) ![]const u8 {
    if (std.mem.eql(u8, assetType, "display")) {
        return std.fmt.allocPrint(allocator, "display/{s}", .{assetId});
    }
    if (std.mem.eql(u8, assetType, "thumb")) {
        return std.fmt.allocPrint(allocator, "thumb/{s}", .{assetId});
    }
    return std.fmt.allocPrint(allocator, "asset/{s}", .{assetId});
}

//
// If output path is a directory, use original filename with type suffix
//
fn getOutputFileName(allocator: std.mem.Allocator, originalName: []const u8, assetType: []const u8) ![]const u8 {
    if (std.mem.eql(u8, assetType, "original")) {
        return originalName;
    }

    const ext = path.extname(originalName);
    const fullBase = path.basename(originalName);

    // `path.basename(originalName, ext)`: the suffix is removed unless it is the whole name.
    const base = if (ext.len > 0 and ext.len < fullBase.len and std.mem.endsWith(u8, fullBase, ext)) fullBase[0 .. fullBase.len - ext.len] else fullBase;
    return std.fmt.allocPrint(allocator, "{s}_{s}{s}", .{ base, assetType, ext });
}

//
// Streams a file from storage to a new local file (TypeScript:
// `pipeline(await assetStorage.readStream(assetStoragePath), createWriteStream(outputFilePath))`).
// Both streams are finished before it returns.
//
fn streamToFile(io: std.Io, storage: IStorage, allocator: std.mem.Allocator, storagePath: []const u8, outputFilePath: []const u8) !void {
    const assetStream = try storage.readStream(allocator, io, storagePath);
    defer assetStream.destroy(io);
    const outputFile = try std.Io.Dir.cwd().createFile(io, outputFilePath, .{});
    defer outputFile.close(io);
    var writeBuffer: [64 * 1024]u8 = undefined;
    var fileWriter = outputFile.writerStreaming(io, &writeBuffer);
    _ = try assetStream.reader().streamRemaining(&fileWriter.interface);
    try fileWriter.interface.flush();
}

//
// Command that exports a particular asset by ID to a specified path.
//
pub fn exportCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, assetId: []const u8, outputPath: []const u8, options: *IExportCommandOptions) !void {
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionId = context.sessionId;
    const assetType = if (options.type) |value| (if (value.len > 0) value else "original") else "original";
    const dbPath = if (options.base.db) |db| (if (db.len > 0) db else try std.process.currentPathAlloc(io, allocator)) else try std.process.currentPathAlloc(io, allocator);

    const loaded = try loadDatabase(allocator, io, dbPath, &options.base, uuidGenerator, timestampProvider, sessionId, false);
    const metadataDatabase = loaded.bsonDatabase;
    const localStorage = loaded.assetStorage;
    const rawAssetStorage = loaded.rawAssetStorage;
    const metadataCollection = try metadataDatabase.collection("metadata");

    // A partial database may have dropped this original locally because the origin holds it. Reading
    // through origin-backed storage is what fetches it back, so exporting works whether the file is
    // on this machine or only on the remote.
    const assetStorage = try openLazyOriginStorage(allocator, io, localStorage, rawAssetStorage);

    const asset = try metadataCollection.getOne(io, assetId) orelse {
        log.@"error"(try std.fmt.allocPrint(allocator, "Asset {s} not found in database.", .{assetId}));
        exit(io, 1);
    };

    const assetStoragePath = try getAssetStoragePath(allocator, assetId, assetType);

    // There is deliberately no existence check on the file here. A partial database does not hold
    // every original on disk: an original the origin already has may have been dropped to save
    // space, and is fetched back from the origin when it is read. An existence check only ever looks
    // locally, so it reported an evicted original as missing from the database when the record was
    // right there and the file was one read away. The read below is what decides: if the file is
    // absent locally and the origin cannot supply it, it fails and says so.

    // Prepare output path
    const outputDir = path.dirname(outputPath);
    try ensureDir(io, outputDir);

    var outputFilePath = outputPath;
    if (std.Io.Dir.cwd().statFile(io, outputPath, .{})) |stat| {
        if (stat.kind == .directory) {
            const origFileName = try js_value.toString(allocator, asset.get("origFileName") orelse .undefined);
            const outputFileName = try getOutputFileName(allocator, origFileName, assetType);
            outputFilePath = try path.join(allocator, &.{ outputPath, outputFileName });
        }
    }
    else |_| {
        // If file doesn't exist, assume it's a file path
    }

    // Stream the asset from storage to the output file
    try streamToFile(io, assetStorage, allocator, assetStoragePath, outputFilePath);

    log.info(try pc.green(allocator, try std.fmt.allocPrint(allocator, "\u{2713} Successfully exported {s} version of asset {s} to {s}", .{ assetType, assetId, outputFilePath })));

    exit(io, 0);
}
