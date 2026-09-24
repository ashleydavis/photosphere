//
// Verify worker handler - handles file verification tasks
//

const std = @import("std");
const utils = @import("utils-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const task_queue_zig = @import("task-queue-zig");
const storage_zig = @import("storage-zig");
const api = @import("api-zig");
const open_storage = @import("open-storage.zig");
const hash = @import("hash.zig");
const retry_operations = @import("retry-operations.zig");
const errors = utils.errors;
const log = &utils.log.log;
const retry = utils.retry.retry;
const formatFileSize = utils.format.formatFileSize;
const SortNode = merkle_tree_zig.merkle_tree.SortNode;
const IHashedData = merkle_tree_zig.merkle_tree.IHashedData;
const ITaskContext = task_queue_zig.types.ITaskContext;
const IStorage = storage_zig.storage.IStorage;
const IFileInfo = storage_zig.storage.IFileInfo;
const LARGE_FILE_TIMEOUT = api.constants.LARGE_FILE_TIMEOUT;
const IDatabaseDescriptor = api.database_descriptor.IDatabaseDescriptor;
const openStorage = open_storage.openStorage;
const computeAssetHash = hash.computeAssetHash;

//
// The options of a verify-file task (TypeScript: the anonymous `{ full?: boolean }` type).
//
pub const IVerifyFileOptions = struct {
    // Enables full verification (not used by the handler, like TypeScript).
    full: ?bool = null,
};

//
// The data of a verify-file task.
//
pub const IVerifyFileData = struct {
    // The sort tree leaf of the file to verify.
    node: SortNode,

    // Identifies the database that holds the file.
    storageDescriptor: IDatabaseDescriptor,

    // The verification options.
    options: ?IVerifyFileOptions = null,
};

//
// The status of a verified file (TypeScript: the "unmodified" | "modified" | "removed" | "new" string union).
//
pub const VerifyFileStatus = enum {
    // The file is unchanged.
    unmodified,

    // The file content has changed.
    modified,

    // The file is missing.
    removed,

    // The file is new.
    new,
};

//
// The result of a verify-file task.
//
pub const IVerifyFileResult = struct {
    // The file that was verified.
    fileName: []const u8,

    // The verification status.
    status: VerifyFileStatus,

    // Why the file is considered modified.
    reasons: ?[]const []const u8 = null,
};

//
// Converts verify-file task data to the JSON value that is queued. TypeScript posts the objects to Bun workers
// (structured clone keeps the Buffer and Date); Zig queues JSON, so the leaf's content hash is a hex string and
// lastModified is milliseconds since the epoch. Only the leaf fields are sent (the leaf has no children).
// (No TypeScript counterpart.)
//
pub fn verifyFileDataToJson(allocator: std.mem.Allocator, data: IVerifyFileData) !std.json.Value {
    var node: std.json.ObjectMap = .empty;
    if (data.node.contentHash) |contentHash| {
        try node.put(allocator, "contentHash", .{ .string = try std.fmt.allocPrint(allocator, "{x}", .{contentHash}) });
    }
    if (data.node.name) |name| {
        try node.put(allocator, "name", .{ .string = name });
    }
    try node.put(allocator, "nodeCount", .{ .integer = data.node.nodeCount });
    try node.put(allocator, "leafCount", .{ .integer = data.node.leafCount });
    try node.put(allocator, "size", .{ .integer = @intCast(data.node.size) });
    if (data.node.lastModified) |lastModified| {
        try node.put(allocator, "lastModified", .{ .integer = lastModified });
    }
    try node.put(allocator, "minName", .{ .string = data.node.minName });

    var storageDescriptor: std.json.ObjectMap = .empty;
    try storageDescriptor.put(allocator, "databasePath", .{ .string = data.storageDescriptor.databasePath });
    if (data.storageDescriptor.encryptionKey) |encryptionKey| {
        try storageDescriptor.put(allocator, "encryptionKey", .{ .string = encryptionKey });
    }

    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "node", .{ .object = node });
    try object.put(allocator, "storageDescriptor", .{ .object = storageDescriptor });
    if (data.options) |options| {
        var optionsObject: std.json.ObjectMap = .empty;
        if (options.full) |full| {
            try optionsObject.put(allocator, "full", .{ .bool = full });
        }
        try object.put(allocator, "options", .{ .object = optionsObject });
    }
    return .{ .object = object };
}

//
// Gets a string property of a JSON object (null when it is absent or not a string). (No TypeScript counterpart.)
//
fn jsonString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse {
        return null;
    };
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

//
// Gets an integer property of a JSON object (null when it is absent or not an integer). (No TypeScript counterpart.)
//
fn jsonInteger(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse {
        return null;
    };
    return switch (value) {
        .integer => |integer| integer,
        else => null,
    };
}

//
// Gets an object property of a JSON object (an empty object when it is absent or not an object).
// (No TypeScript counterpart.)
//
fn jsonObject(object: std.json.ObjectMap, key: []const u8) std.json.ObjectMap {
    const value = object.get(key) orelse {
        return .empty;
    };
    return switch (value) {
        .object => |child| child,
        else => .empty,
    };
}

//
// Converts the JSON value of a verify-file task back to IVerifyFileData (the reverse of verifyFileDataToJson).
// (No TypeScript counterpart.)
//
pub fn verifyFileDataFromJson(allocator: std.mem.Allocator, value: std.json.Value) !IVerifyFileData {
    const object = switch (value) {
        .object => |object| object,
        else => std.json.ObjectMap.empty,
    };
    const node = jsonObject(object, "node");
    var contentHash: ?[]const u8 = null;
    if (jsonString(node, "contentHash")) |contentHashHex| {
        const bytes = try allocator.alloc(u8, contentHashHex.len / 2);
        contentHash = try std.fmt.hexToBytes(bytes, contentHashHex);
    }
    const storageDescriptor = jsonObject(object, "storageDescriptor");
    var options: ?IVerifyFileOptions = null;
    if (object.get("options")) |optionsValue| {
        if (optionsValue == .object) {
            const full = optionsValue.object.get("full");
            options = .{ .full = if (full != null and full.? == .bool) full.?.bool else null };
        }
    }
    return .{
        .node = .{
            .contentHash = contentHash,
            .name = jsonString(node, "name"),
            .nodeCount = @intCast(jsonInteger(node, "nodeCount") orelse 1),
            .leafCount = @intCast(jsonInteger(node, "leafCount") orelse 1),
            .size = @intCast(jsonInteger(node, "size") orelse 0),
            .lastModified = jsonInteger(node, "lastModified"),
            .minName = jsonString(node, "minName") orelse "",
        },
        .storageDescriptor = .{
            .databasePath = jsonString(storageDescriptor, "databasePath") orelse "",
            .encryptionKey = jsonString(storageDescriptor, "encryptionKey"),
        },
        .options = options,
    };
}

//
// Converts a verify-file result to the JSON value returned as the task output. (No TypeScript counterpart.)
//
pub fn verifyFileResultToJson(allocator: std.mem.Allocator, result: IVerifyFileResult) !std.json.Value {
    const text = try std.json.Stringify.valueAlloc(allocator, result, .{ .emit_null_optional_fields = false });
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

//
// Formats a date like JavaScript's `date.toLocaleString()` in the en-US locale ("M/D/YYYY, h:mm:ss AM"), in UTC
// (the time zone of the environments psi runs its tests in). (No TypeScript counterpart: a JavaScript built-in.)
//
pub fn toLocaleString(allocator: std.mem.Allocator, epochMilliseconds: i64) ![]const u8 {
    const millisecondsPerDay: i64 = 24 * 60 * 60 * 1000;
    const days = @divFloor(epochMilliseconds, millisecondsPerDay);
    const millisecondOfDay = @mod(epochMilliseconds, millisecondsPerDay);

    // Howard Hinnant's civil_from_days algorithm.
    const shiftedDays = days + 719468;
    const era = @divFloor(shiftedDays, 146097);
    const dayOfEra = shiftedDays - era * 146097;
    const yearOfEra = @divFloor(dayOfEra - @divFloor(dayOfEra, 1460) + @divFloor(dayOfEra, 36524) - @divFloor(dayOfEra, 146096), 365);
    const dayOfYear = dayOfEra - (365 * yearOfEra + @divFloor(yearOfEra, 4) - @divFloor(yearOfEra, 100));
    const monthIndex = @divFloor(5 * dayOfYear + 2, 153);
    const day = dayOfYear - @divFloor(153 * monthIndex + 2, 5) + 1;
    const month = if (monthIndex < 10) monthIndex + 3 else monthIndex - 9;
    const year = yearOfEra + era * 400 + @as(i64, if (month <= 2) 1 else 0);

    const hours = @divFloor(millisecondOfDay, 60 * 60 * 1000);
    const minutes = @mod(@divFloor(millisecondOfDay, 60 * 1000), 60);
    const seconds = @mod(@divFloor(millisecondOfDay, 1000), 60);
    const hour12 = if (@mod(hours, 12) == 0) 12 else @mod(hours, 12);
    const meridiem = if (hours < 12) "AM" else "PM";
    return std.fmt.allocPrint(allocator, "{d}/{d}/{d}, {d}:{d:0>2}:{d:0>2} {s}", .{
        @as(u64, @intCast(month)),
        @as(u64, @intCast(day)),
        @as(u64, @intCast(year)),
        @as(u64, @intCast(hour12)),
        @as(u64, @intCast(minutes)),
        @as(u64, @intCast(seconds)),
        meridiem,
    });
}

//
// `async () => computeAssetHash(await storage.readStream(fileName), fileInfo)`.
//
const ComputeAssetHashOperation = struct {
    // Allocates the hash.
    allocator: std.mem.Allocator,

    // The storage holding the file.
    storage: IStorage,

    // The file to hash.
    fileName: []const u8,

    // The information about the file.
    fileInfo: IFileInfo,

    //
    // Streams the file and hashes it.
    //
    pub fn run(self: *ComputeAssetHashOperation, io: std.Io) !IHashedData {
        const readStream = try self.storage.readStream(self.allocator, io, self.fileName);
        defer readStream.destroy(io);
        return computeAssetHash(self.allocator, readStream.reader(), .{
            .contentType = self.fileInfo.contentType,
            .length = self.fileInfo.length,
            .lastModified = self.fileInfo.lastModified,
        });
    }
};

//
// Handler for verifying a single file
// (Zig: the task data is the JSON value made by verifyFileDataToJson and the output is an IVerifyFileResult as JSON.)
//
pub fn verifyFileHandler(allocator: std.mem.Allocator, io: std.Io, taskData: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = context;
    const data = try verifyFileDataFromJson(allocator, taskData);
    const node = data.node;
    const storageDescriptor = data.storageDescriptor;
    const fileName = node.name orelse "";

    const opened = try openStorage(allocator, io, storageDescriptor.databasePath, storageDescriptor.encryptionKey, null);
    const storage = opened.storage;

    var infoOperation: retry_operations.InfoOperation = .{ .allocator = allocator, .storage = storage, .fileName = fileName };
    const fileInfo = try retry(io, &infoOperation, 3, 1_000, 2, 30_000, null) orelse {
        return verifyFileResultToJson(allocator, .{
            .fileName = fileName,
            .status = .removed,
        });
    };

    const sizeChanged = node.size != fileInfo.length;
    const timestampChanged = node.lastModified == null or node.lastModified.? != fileInfo.lastModified;
    if (sizeChanged or timestampChanged) {
        // File metadata has changed - check if content actually changed by computing the hash.
        var hashOperation: ComputeAssetHashOperation = .{ .allocator = allocator, .storage = storage, .fileName = fileName, .fileInfo = fileInfo };
        const freshHash = try retry(io, &hashOperation, 3, 1_000, 2, LARGE_FILE_TIMEOUT, null);
        const contentHash = node.contentHash orelse {
            return errors.throwError("The \"target\" argument must be an instance of Buffer or Uint8Array. Received undefined", .{});
        };
        if (!std.mem.eql(u8, freshHash.hash, contentHash)) {
            // The file content has actually been modified.
            var reasons: std.ArrayList([]const u8) = .empty;
            if (sizeChanged) {
                const oldSize = try formatFileSize(allocator, node.size);
                const newSize = try formatFileSize(allocator, fileInfo.length);
                try reasons.append(allocator, try std.fmt.allocPrint(allocator, "size changed ({s} → {s})", .{ oldSize, newSize }));
            }
            if (timestampChanged) {
                const lastModified = node.lastModified orelse {
                    return errors.throwError("undefined is not an object (evaluating 'node.lastModified.toLocaleString')", .{});
                };
                const oldTime = try toLocaleString(allocator, lastModified);
                const newTime = try toLocaleString(allocator, fileInfo.lastModified);
                try reasons.append(allocator, try std.fmt.allocPrint(allocator, "timestamp changed ({s} → {s})", .{ oldTime, newTime }));
            }
            try reasons.append(allocator, "content hash changed");

            if (log.verboseEnabled()) {
                log.verbose(try std.fmt.allocPrint(allocator, "Modified file: {s} - {s}", .{ fileName, try std.mem.join(allocator, ", ", reasons.items) }));
            }

            return verifyFileResultToJson(allocator, .{
                .fileName = fileName,
                .status = .modified,
                .reasons = reasons.items,
            });
        }
        else {
            // Metadata changed but content is the same - file is unmodified.
            return verifyFileResultToJson(allocator, .{
                .fileName = fileName,
                .status = .unmodified,
            });
        }
    }
    else {
        // File metadata hasn't changed - file is unmodified.
        return verifyFileResultToJson(allocator, .{
            .fileName = fileName,
            .status = .unmodified,
        });
    }
}
