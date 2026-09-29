//
// Shows the origin database path from .db/config.json.
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
const loadDatabaseConfig = api.database_config.loadDatabaseConfig;

//
// Options of the origin command (TypeScript: IOriginCommandOptions extends IBaseCommandOptions).
// The base options are in `base`.
//
pub const IOriginCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},
};

//
// Gets `config?.origin` from the parsed config (null when the config or the key is missing, or the config is
// not an object).
//
fn getOrigin(config: ?std.json.Value) ?std.json.Value {
    const value = config orelse return null;
    return switch (value) {
        .object => |object| object.get("origin"),
        else => null,
    };
}

//
// JavaScript truthiness of a JSON value.
//
fn isTruthy(value: std.json.Value) bool {
    return switch (value) {
        .null => false,
        .bool => |flag| flag,
        .integer => |number| number != 0,
        .float => |number| isTruthyNumber(number),
        .number_string => |text| isTruthyNumber(std.fmt.parseFloat(f64, text) catch std.math.nan(f64)),
        .string => |text| text.len > 0,
        .array, .object => true,
    };
}

//
// Formats a JSON value like JavaScript's `String(value)`.
//
fn jsString(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return switch (value) {
        .null => "null",
        .bool => |flag| if (flag) "true" else "false",
        .integer => |number| jsNumberString(allocator, @floatFromInt(number)),
        .float => |number| jsNumberString(allocator, number),
        .number_string => |text| jsNumberString(allocator, std.fmt.parseFloat(f64, text) catch std.math.nan(f64)),
        .string => |text| text,
        .object => "[object Object]",
        .array => |array| blk: {
            var joined: std.ArrayList(u8) = .empty;
            for (array.items, 0..) |item, index| {
                if (index > 0) {
                    try joined.append(allocator, ',');
                }
                if (item != .null) {
                    try joined.appendSlice(allocator, try jsString(allocator, item));
                }
            }
            break :blk joined.items;
        },
    };
}

//
// Command that shows the origin of the database.
//
pub fn originCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, options: *IOriginCommandOptions) !void {
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionId = context.sessionId;

    const loaded = try loadDatabase(allocator, io, options.base.db, &options.base, uuidGenerator, timestampProvider, sessionId, false);
    const config = try loadDatabaseConfig(allocator, io, loaded.rawAssetStorage);

    const origin = getOrigin(config);
    if (origin != null and isTruthy(origin.?)) {
        log.info(try jsString(allocator, origin.?));
    }
    else {
        log.info(try pc.gray(allocator, "(not set)"));
    }

    exit(io, 0);
}

//
// `String(number)`: the number as JavaScript writes it.
//
fn jsNumberString(allocator: std.mem.Allocator, number: f64) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    try utils.js_number.writeNumber(&output.writer, number);
    return output.written();
}

//
// JavaScript truthiness of a number.
//
fn isTruthyNumber(number: f64) bool {
    return number != 0 and !std.math.isNan(number);
}
