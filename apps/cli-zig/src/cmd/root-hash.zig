const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const init_cmd = @import("../lib/init-cmd.zig");
const exit = node_utils.termination.exit;
const loadDatabase = init_cmd.loadDatabase;
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;
const ICommandContext = init_cmd.ICommandContext;
const getDatabaseSummary = node_api.media_file_database.getDatabaseSummary;

//
// Options of the root-hash command.
// The base options are in `base`.
//
pub const IRootHashCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},
};

//
// Command to display the aggregate root hash of the database.
//
pub fn rootHashCommand(allocator: std.mem.Allocator, io: std.Io, log: ILog, context: ICommandContext, options: *IRootHashCommandOptions) !void {
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionId = context.sessionId;
    const loaded = try loadDatabase(allocator, io, log, options.base.db, &options.base, uuidGenerator, timestampProvider, sessionId, context.toolRunner, false);
    const assetStorage = loaded.assetStorage;

    const summary = try getDatabaseSummary(allocator, io, log, assetStorage);

    log.info(summary.fullHash);

    exit(io, log, 0);
}
