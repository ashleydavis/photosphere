const std = @import("std");
const storage_zig = @import("storage-zig");
const serialization_zig = @import("serialization-zig");
const bdb = @import("bdb-zig");
const node_path = @import("node-utils-zig").path;
const IStorage = storage_zig.storage.IStorage;
const BsonDocument = serialization_zig.bson.BsonDocument;
const parseDate = serialization_zig.js_date.parseDate;
const IBsonDatabase = bdb.database.BsonDatabase;

//
// A media file record (TypeScript: IAsset from asset.ts, which is not ported; Zig records are the BSON documents
// they are stored as).
//
pub const IAsset = BsonDocument;

//
// Result of a paginated asset listing.
//
pub const IListAssetsResult = struct {
    //
    // Page of assets.
    //
    assets: []const IAsset,

    //
    // Opaque token to pass back for the next page. Null (undefined) when there are no more pages.
    //
    nextPageId: ?[]const u8 = null,
};

//
// Asset type used by export operations. Maps to a storage prefix.
//
pub const AssetExportType = enum {
    // The original file (asset/).
    original,

    // The display version (display/).
    display,

    // The thumbnail (thumb/).
    thumb,
};

//
// Returns one page of assets from the metadata collection, sorted by photoDate descending.
//
pub fn listAssetPage(io: std.Io, bsonDatabase: *IBsonDatabase, limit: usize, pageId: ?[]const u8) !IListAssetsResult {
    const metadataCollection = try bsonDatabase.collection("metadata");
    const sortIndex = try metadataCollection.sortIndex("photoDate", .desc);
    const page = try sortIndex.getPage(io, pageId);
    const assets = page.records[0..@min(limit, page.records.len)];
    return .{
        .assets = assets,
        .nextPageId = page.nextPageId,
    };
}

//
// Searches assets in the metadata collection using an in-memory filter.
// Matches case-insensitive substring on origFileName and location, prefix on contentType,
// and a date range on photoDate.
// (Zig: the strings are lowercased with ASCII rules, where JavaScript's toLowerCase also lowercases other letters.)
//
pub fn searchAssets(
    allocator: std.mem.Allocator,
    io: std.Io,
    bsonDatabase: *IBsonDatabase,
    query: []const u8,
    contentType: ?[]const u8,
    dateFrom: ?[]const u8,
    dateTo: ?[]const u8,
    limit: usize,
) ![]const IAsset {
    const metadataCollection = try bsonDatabase.collection("metadata");

    const queryLower = try std.ascii.allocLowerString(allocator, query);
    const contentTypePrefix: ?[]const u8 = if (isTruthy(contentType)) try std.ascii.allocLowerString(allocator, contentType.?) else null;
    const dateFromMs: ?f64 = if (isTruthy(dateFrom)) parseDate(dateFrom.?) else null;
    const dateToMs: ?f64 = if (isTruthy(dateTo)) parseDate(dateTo.?) else null;

    var matches: std.ArrayList(IAsset) = .empty;

    var nextToken: ?[]const u8 = null;
    while (true) {
        const pageResult = try metadataCollection.getAll(io, nextToken);
        for (pageResult.records) |asset| {
            if (!try matchesAsset(allocator, asset, queryLower, contentTypePrefix, dateFromMs, dateToMs)) {
                continue;
            }
            try matches.append(allocator, asset);
            if (matches.items.len >= limit) {
                return matches.items;
            }
        }
        nextToken = pageResult.next;
        if (!isTruthy(nextToken)) {
            break;
        }
    }

    return matches.items;
}

//
// True when an optional string is truthy in JavaScript (set and not empty). (No TypeScript counterpart: the
// truthiness tests are inline.)
//
fn isTruthy(value: ?[]const u8) bool {
    return value != null and value.?.len > 0;
}

//
// The value of a string field of an asset, or "" when it is missing or not a string
// (TypeScript: `asset.field || ""`).
//
fn stringField(asset: IAsset, name: []const u8) []const u8 {
    const value = asset.get(name) orelse {
        return "";
    };
    return switch (value) {
        .string => |text| text,
        else => "",
    };
}

//
// The milliseconds since the epoch of an asset's photoDate (TypeScript: `Date.parse(asset.photoDate)`), or null
// when the asset has no photoDate (TypeScript: `!asset.photoDate`). NaN when the date does not parse.
// A photoDate stored as a date is converted to a string first by Date.parse, which drops its milliseconds.
//
fn photoDateMs(asset: IAsset) ?f64 {
    const value = asset.get("photoDate") orelse {
        return null;
    };
    switch (value) {
        .string => |text| {
            if (text.len == 0) {
                return null;
            }
            return parseDate(text);
        },
        .date => |time| {
            return @floatFromInt(@divFloor(time, 1000) * 1000);
        },
        else => {
            return null;
        },
    }
}

//
// True if the asset matches all of the supplied filters.
//
fn matchesAsset(
    allocator: std.mem.Allocator,
    asset: IAsset,
    queryLower: []const u8,
    contentTypePrefix: ?[]const u8,
    dateFromMs: ?f64,
    dateToMs: ?f64,
) !bool {
    if (queryLower.len > 0) {
        const origFileName = try std.ascii.allocLowerString(allocator, stringField(asset, "origFileName"));
        const location = try std.ascii.allocLowerString(allocator, stringField(asset, "location"));
        if (std.mem.indexOf(u8, origFileName, queryLower) == null and std.mem.indexOf(u8, location, queryLower) == null) {
            return false;
        }
    }
    if (contentTypePrefix) |prefix| {
        const assetContentType = try std.ascii.allocLowerString(allocator, stringField(asset, "contentType"));
        if (!std.mem.startsWith(u8, assetContentType, prefix)) {
            return false;
        }
    }
    if (dateFromMs != null or dateToMs != null) {
        const photoMs = photoDateMs(asset) orelse {
            return false;
        };
        if (std.math.isNan(photoMs)) {
            return false;
        }
        if (dateFromMs != null and photoMs < dateFromMs.?) {
            return false;
        }
        if (dateToMs != null and photoMs > dateToMs.?) {
            return false;
        }
    }
    return true;
}

//
// Returns a single asset by id, or null (undefined) if not found.
//
pub fn getAsset(io: std.Io, bsonDatabase: *IBsonDatabase, assetId: []const u8) !?IAsset {
    const metadataCollection = try bsonDatabase.collection("metadata");
    return metadataCollection.getOne(io, assetId);
}

//
// Streams an asset from storage to a file on disk and returns the number of bytes written.
// Maps type to a storage prefix (asset/, display/, thumb/) and creates parent directories.
//
pub fn streamAssetToFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    assetStorage: IStorage,
    assetId: []const u8,
    outputPath: []const u8,
    @"type": []const u8,
) !u64 {
    const storageKey = try mapAssetTypeToStorageKey(allocator, @"type", assetId);
    try std.Io.Dir.cwd().createDirPath(io, node_path.dirname(outputPath));

    const readStream = try assetStorage.readStream(allocator, io, storageKey);
    defer readStream.destroy(io);

    const outputFile = try std.Io.Dir.cwd().createFile(io, outputPath, .{});
    defer outputFile.close(io);
    var writeBuffer: [64 * 1024]u8 = undefined;
    var fileWriter = outputFile.writerStreaming(io, &writeBuffer);
    const bytesWritten = try readStream.reader().streamRemaining(&fileWriter.interface);
    try fileWriter.interface.flush();
    return bytesWritten;
}

//
// Maps an MCP asset export type to a storage path.
//
fn mapAssetTypeToStorageKey(allocator: std.mem.Allocator, @"type": []const u8, assetId: []const u8) ![]const u8 {
    if (std.mem.eql(u8, @"type", "display")) {
        return std.fmt.allocPrint(allocator, "display/{s}", .{assetId});
    }
    if (std.mem.eql(u8, @"type", "thumb")) {
        return std.fmt.allocPrint(allocator, "thumb/{s}", .{assetId});
    }
    return std.fmt.allocPrint(allocator, "asset/{s}", .{assetId});
}
