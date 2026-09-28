const std = @import("std");
const serialization_zig = @import("serialization-zig");
const api = @import("api-zig");
const protocol = @import("protocol.zig");
const types = @import("types.zig");
const BsonValue = serialization_zig.bson.BsonValue;
const BsonDocument = serialization_zig.bson.BsonDocument;
const IAsset = api.asset_query.IAsset;
const CallToolResult = protocol.ICallToolResult;
const ITextContent = protocol.ITextContent;
const ICurrentDatabase = types.ICurrentDatabase;
const IMcpToolContext = types.IMcpToolContext;

//
// Standard "no database open" message returned by every database-scoped tool.
//
pub const NO_DATABASE_MESSAGE = "No database is currently open. Use list_databases / open_database first.";

//
// Wraps plain text as an MCP CallToolResult with a single text content block.
//
pub fn textResult(allocator: std.mem.Allocator, text: []const u8) !CallToolResult {
    const content = try allocator.alloc(ITextContent, 1);
    content[0] = .{
        .type = "text",
        .text = text,
    };
    return .{
        .content = content,
    };
}

//
// The currently open database, or the result a tool answers with when none is open
// (TypeScript: `ICurrentDatabase | CallToolResult`).
//
pub const IDatabaseOrResult = union(enum) {
    // The open database.
    database: ICurrentDatabase,

    // The "no database open" result.
    result: CallToolResult,
};

//
// Returns the currently open database from the context, or a text-result error block when
// no database is open. Tool handlers can dispatch on the type to branch on the guard.
//
pub fn requireDatabase(allocator: std.mem.Allocator, toolContext: *const IMcpToolContext) !IDatabaseOrResult {
    const database = toolContext.getDatabase() orelse {
        return .{ .result = try textResult(allocator, NO_DATABASE_MESSAGE) };
    };
    return .{ .database = database };
}

//
// Reduces a full IAsset to the slimmer summary returned by list/search tools.
// (Zig: a field the asset does not have is undefined, which JSON.stringify leaves out.)
//
pub fn toAssetSummary(allocator: std.mem.Allocator, asset: IAsset) !BsonValue {
    var summary: BsonDocument = .empty;
    for ([_][]const u8{ "_id", "origFileName", "contentType", "photoDate", "width", "height", "location", "coordinates" }) |name| {
        try summary.put(allocator, name, asset.get(name) orelse .undefined);
    }
    return .{ .document = summary };
}

//
// Converts a result of the Zig libraries to the JavaScript value its TypeScript counterpart is, for JSON.stringify:
// a struct becomes an object with its fields in order, null (undefined) fields left out, an enum its name, an
// integer or float a number, a string a string and a slice an array. (No TypeScript counterpart: the TypeScript
// results are already JavaScript values.)
//
pub fn toJsValue(allocator: std.mem.Allocator, value: anytype) !BsonValue {
    const ValueType = @TypeOf(value);
    switch (@typeInfo(ValueType)) {
        .optional => {
            if (value) |present| {
                return toJsValue(allocator, present);
            }
            return .undefined;
        },
        .int, .comptime_int => {
            return .{ .number = @floatFromInt(value) };
        },
        .float, .comptime_float => {
            return .{ .number = @floatCast(value) };
        },
        .bool => {
            return .{ .boolean = value };
        },
        .@"enum" => {
            return .{ .string = @tagName(value) };
        },
        .pointer => |pointer| {
            if (pointer.size != .slice) {
                @compileError("toJsValue does not convert " ++ @typeName(ValueType));
            }
            if (pointer.child == u8) {
                return .{ .string = value };
            }
            const elements = try allocator.alloc(BsonValue, value.len);
            for (value, 0..) |element, elementIndex| {
                elements[elementIndex] = try toJsValue(allocator, element);
            }
            return .{ .array = elements };
        },
        .@"struct" => |structInfo| {
            var document: BsonDocument = .empty;
            inline for (structInfo.fields) |field| {
                try document.put(allocator, field.name, try toJsValue(allocator, @field(value, field.name)));
            }
            return .{ .document = document };
        },
        else => {
            @compileError("toJsValue does not convert " ++ @typeName(ValueType));
        },
    }
}
