//
// Sets the origin database path in .db/config.json.
//

const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const api = @import("api-zig");
const pc = @import("../lib/picocolors.zig");
const init_cmd = @import("../lib/init-cmd.zig");
const log = &utils.log.log;
const exit = node_utils.termination.exit;
const loadDatabase = init_cmd.loadDatabase;
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;
const ICommandContext = init_cmd.ICommandContext;
const updateDatabaseConfig = api.database_config.updateDatabaseConfig;

//
// Options of the set-origin command (TypeScript: ISetOriginCommandOptions extends IBaseCommandOptions).
// The base options are in `base`.
//
pub const ISetOriginCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},
};

//
// Command that sets the origin of the database.
// (Zig: `{ ...existing ?? {}, origin }` is passed as just the origin, because updateDatabaseConfig spreads the
// existing config first itself, so the existing keys are written in the same order either way.)
//
pub fn setOriginCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, options: *ISetOriginCommandOptions, originPath: []const u8) !void {
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionId = context.sessionId;

    const loaded = try loadDatabase(allocator, io, options.base.db, &options.base, uuidGenerator, timestampProvider, sessionId, false);
    try updateDatabaseConfig(allocator, io, loaded.rawAssetStorage, .{ .origin = originPath });

    log.info(try pc.green(allocator, try std.fmt.allocPrint(allocator, "\u{2713} Origin set to: {s}", .{originPath})));
    exit(io, 0);
}
