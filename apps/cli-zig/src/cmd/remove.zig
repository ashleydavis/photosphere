const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const pc = @import("../lib/picocolors.zig");
const init_cmd = @import("../lib/init-cmd.zig");
const log = &utils.log.log;
const exit = node_utils.termination.exit;
const loadDatabase = init_cmd.loadDatabase;
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;
const ICommandContext = init_cmd.ICommandContext;
const removeAsset = node_api.media_file_database.removeAsset;

//
// Options of the remove command (TypeScript: IRemoveCommandOptions extends IBaseCommandOptions).
// The base options are in `base`.
//
pub const IRemoveCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},
};

//
// Command that removes a particular asset by ID from the database.
//
pub fn removeCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, assetId: []const u8, options: *IRemoveCommandOptions) !void {
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionId = context.sessionId;
    const dbPath = if (options.base.db) |db| (if (db.len > 0) db else try std.process.currentPathAlloc(io, allocator)) else try std.process.currentPathAlloc(io, allocator);

    // Load the database using shared function
    const loaded = try loadDatabase(allocator, io, dbPath, &options.base, uuidGenerator, timestampProvider, sessionId, false);

    // Remove the asset using the comprehensive removal method
    try removeAsset(allocator, io, loaded.assetStorage, loaded.rawAssetStorage, sessionId, loaded.bsonDatabase, loaded.metadataCollection, assetId, true);

    log.info(try pc.green(allocator, try std.fmt.allocPrint(allocator, "\u{2713} Successfully removed asset {s} from database", .{assetId})));

    exit(io, 0);
}
