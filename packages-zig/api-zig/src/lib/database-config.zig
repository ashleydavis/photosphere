//
// Database config stored at .db/config.json.
// Created on init/upgrade; holds configuration only (currently origin).
// Runtime values (lastModifiedAt, lastSyncedAt, lastReplicatedAt, contentHash) live in the state
// file (.db/state.dat, see database-state.ts).
//

const std = @import("std");
const utils = @import("utils-zig");
const storage_zig = @import("storage-zig");
const IStorage = storage_zig.storage.IStorage;
const retry = utils.retry.retry;
const errors = utils.errors;

//
// The path of the config file relative to the database root.
//
const CONFIG_PATH = ".db/config.json";

//
// The database config. Every field is optional, as in TypeScript (null means the key is absent).
// The `= null` defaults let std.json parse objects that leave keys out.
//
pub const IDatabaseConfig = struct {
    // Path or URI of the database this copy was replicated from.
    origin: ?[]const u8 = null,
};

//
// Reads .db/config.json for retry (the `() => rawStorage.read(CONFIG_PATH)` of TypeScript).
//
const ReadConfigOperation = struct {
    // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
    // (Bun inlines the module constant CONFIG_PATH into the function's source.)
    pub const source = "() => rawStorage.read(\".db/config.json\")";

    // Allocator for the file contents.
    allocator: std.mem.Allocator,

    // The storage to read from.
    rawStorage: IStorage,

    //
    // Reads the config file.
    //
    pub fn run(self: *ReadConfigOperation, io: std.Io) !?[]u8 {
        return self.rawStorage.read(self.allocator, io, CONFIG_PATH);
    }
};

//
// Writes .db/config.json for retry (the `() => rawStorage.write(CONFIG_PATH, ...)` of TypeScript).
//
const WriteConfigOperation = struct {
    // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
    // (Bun inlines the module constant CONFIG_PATH into the function's source.)
    pub const source = "() => rawStorage.write(\".db/config.json\", \"application/json\", Buffer.from(text, \"utf8\"))";

    // Allocator for the storage implementation's temporary data.
    allocator: std.mem.Allocator,

    // The storage to write to.
    rawStorage: IStorage,

    // The file contents.
    data: []const u8,

    //
    // Writes the config file.
    //
    pub fn run(self: *WriteConfigOperation, io: std.Io) !void {
        return self.rawStorage.write(self.allocator, io, CONFIG_PATH, "application/json", self.data);
    }
};

//
// Loads the database config from .db/config.json. Returns null if the file does not exist.
// (Zig: returns the parsed JSON value, the equivalent of the JavaScript object JSON.parse returns, so that
// updateDatabaseConfig keeps its keys and their order; JSON `null` in the file is returned as .null.)
//
pub fn loadDatabaseConfig(allocator: std.mem.Allocator, io: std.Io, rawStorage: IStorage) !?std.json.Value {
    if (!try rawStorage.fileExists(allocator, io, CONFIG_PATH)) {
        return null;
    }
    var operation: ReadConfigOperation = .{ .allocator = allocator, .rawStorage = rawStorage };
    const data = try retry(io, &operation, 3, 1_000, 2, 30_000, null) orelse {
        return null;
    };
    const text = data;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{ .allocate = .alloc_always }) catch |err| {
        errors.recordError("SyntaxError", "JSON Parse error: {s}", .{@errorName(err)});
        return errors.throwWrappedError("Failed to parse database config at {s}", .{CONFIG_PATH});
    };
    return parsed;
}

//
// Saves the full database config to .db/config.json.
// (Zig: `config` is an IDatabaseConfig or a std.json.Value object; null fields are left out like undefined
// properties are by JSON.stringify.)
//
pub fn saveDatabaseConfig(allocator: std.mem.Allocator, io: std.Io, rawStorage: IStorage, config: anytype) !void {
    const text = try std.json.Stringify.valueAlloc(allocator, config, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
    var operation: WriteConfigOperation = .{ .allocator = allocator, .rawStorage = rawStorage, .data = text };
    try retry(io, &operation, 3, 1_000, 2, 30_000, null);
}

//
// Updates the database config by merging partial into the existing config (or empty object).
//
pub fn updateDatabaseConfig(allocator: std.mem.Allocator, io: std.Io, rawStorage: IStorage, partial: IDatabaseConfig) !void {
    const existing = try loadDatabaseConfig(allocator, io, rawStorage);

    // `{ ...existing ?? {}, ...partial }`: the keys of the existing object in order, then the keys of partial
    // (an existing key keeps its position). Spreading a value that is not an object adds no keys.
    var merged: std.json.ObjectMap = .empty;
    if (existing) |existingValue| {
        switch (existingValue) {
            .object => |existingObject| {
                var iterator = existingObject.iterator();
                while (iterator.next()) |entry| {
                    try merged.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
                }
            },
            else => {},
        }
    }
    inline for (@typeInfo(IDatabaseConfig).@"struct".fields) |field| {
        if (@field(partial, field.name)) |value| {
            try merged.put(allocator, field.name, .{ .string = value });
        }
    }
    try saveDatabaseConfig(allocator, io, rawStorage, std.json.Value{ .object = merged });
}
