const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const init_cmd = @import("../lib/init-cmd.zig");
const log = &utils.log.log;
const exit = node_utils.termination.exit;
const loadDatabase = init_cmd.loadDatabase;
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;
const ICommandContext = init_cmd.ICommandContext;
const loadMerkleTree = node_api.tree.loadMerkleTree;

//
// Options of the database-id command (TypeScript: IDatabaseIdCommandOptions extends IBaseCommandOptions).
// The base options are in `base`.
//
pub const IDatabaseIdCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},
};

//
// Command to display the database ID (UUID) of the database.
//
pub fn databaseIdCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, options: *IDatabaseIdCommandOptions) !void {
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionId = context.sessionId;
    const loaded = try loadDatabase(allocator, io, options.base.db, &options.base, uuidGenerator, timestampProvider, sessionId, false);
    const assetStorage = loaded.assetStorage;

    const merkleTree = try loadMerkleTree(allocator, io, assetStorage) orelse {
        return utils.errors.throwError("Failed to load merkle tree", .{});
    };

    log.info(merkleTree.id);

    exit(io, 0);
}
