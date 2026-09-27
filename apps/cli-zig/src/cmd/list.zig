const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const tools = @import("tools-zig");
const storage_zig = @import("storage-zig");
const serialization = @import("serialization-zig");
const bdb = @import("bdb-zig");
const pc = @import("../lib/picocolors.zig");
const init_cmd = @import("../lib/init-cmd.zig");
const format = @import("../lib/format.zig");
const common = @import("../lib/clack/prompts/common.zig");
const log = &utils.log.log;
const exit = node_utils.termination.exit;
const loadDatabase = init_cmd.loadDatabase;
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;
const ICommandContext = init_cmd.ICommandContext;
const readEncryptionHeader = storage_zig.read_encryption_header.readEncryptionHeader;
const parseInt = tools.image.parseInt;
const js_value = bdb.js_value;
const js_date = serialization.js_date;
const BsonValue = serialization.bson.BsonValue;
const BsonDocument = serialization.bson.BsonDocument;

//
// An asset record from the metadata collection's sort index (TypeScript: IAsset).
//
const IAsset = bdb.sort_index.ISortIndexRecord;

//
// Options of the list command (TypeScript: IListCommandOptions extends IBaseCommandOptions).
// The base options are in `base`.
//
pub const IListCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},

    //
    // Number of files to display per page
    //
    pageSize: ?[]const u8 = null,
};

//
// Command that lists all files in the database with pagination
//
pub fn listCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, options: *IListCommandOptions) !void {
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionId = context.sessionId;
    const loaded = try loadDatabase(allocator, io, options.base.db, &options.base, uuidGenerator, timestampProvider, sessionId, false);
    const bsonDatabase = loaded.bsonDatabase;
    const rawAssetStorage = loaded.rawAssetStorage;
    const pageSizeText = if (options.pageSize) |pageSize| (if (pageSize.len > 0) pageSize else "20") else "20";
    const pageSize = parseInt(pageSizeText);

    const metadataDatabase = bsonDatabase;
    const metadataCollection = try metadataDatabase.collection("metadata");

    log.info("");
    log.info(try pc.bold(allocator, try pc.blue(allocator, "\u{1F4C1} Database Files")));
    log.info("");
    log.info("Files are sorted by date (newest first).");
    log.info("");

    var nextPageId: ?[]const u8 = null;
    var pageNumber: u32 = 1;
    var totalDisplayed: usize = 0;

    while (true) {
        const result = try (try metadataCollection.sortIndex("photoDate", .desc)).getPage(io, nextPageId);

        if (result.records.len == 0) {
            if (totalDisplayed == 0) {
                log.info(try pc.yellow(allocator, "No files found in the database."));
            }
            else {
                log.info(try pc.green(allocator, try std.fmt.allocPrint(allocator, "\nEnd of results. Displayed {d} files total.", .{totalDisplayed})));
            }
            break;
        }

        const pageRecords = result.records[0..sliceEnd(result.records.len, pageSize)];

        // Read encryption headers for each record
        const encryptionHeaders = try allocator.alloc(?[]const u8, pageRecords.len);
        for (pageRecords, 0..) |record, recordIndex| {
            const recordId = try js_value.toString(allocator, record.get("_id").?);
            const hash = try readEncryptionHeader(allocator, io, rawAssetStorage, try std.fmt.allocPrint(allocator, "asset/{s}", .{recordId}));
            encryptionHeaders[recordIndex] = hash;
        }

        // Display current page
        try displayPage(allocator, pageRecords, pageNumber, pageSize, encryptionHeaders);
        totalDisplayed += pageRecords.len;

        // Check if there are more pages
        // Either we have a nextPageId from database or we displayed less than pageSize
        const hasMorePages = isSet(result.nextPageId) and @as(f64, @floatFromInt(pageRecords.len)) == pageSize;

        if (!hasMorePages) {
            log.info(try pc.green(allocator, try std.fmt.allocPrint(allocator, "\nEnd of results. Displayed {d} files total.", .{totalDisplayed})));
            break;
        }

        // Wait for user input
        log.info(try pc.dim(allocator, "Press Enter or any key for next page, Ctrl+C to exit..."));
        const shouldContinue = try waitForUserInput(io);
        if (!shouldContinue) {
            log.info(try pc.cyan(allocator, try std.fmt.allocPrint(allocator, "\nDisplayed {d} files. Exiting.", .{totalDisplayed})));
            break;
        }

        // If we displayed fewer records than available, use the remainder for next page
        if (@as(f64, @floatFromInt(result.records.len)) > pageSize) {
            // We need to keep the remaining records for the next page
            // This is a bit tricky with the current API, so let's keep it simple
            // and just use the database's pagination
            nextPageId = result.nextPageId;
        }
        else {
            nextPageId = result.nextPageId;
        }
        pageNumber += 1;
    }

    exit(io, 0);
}

//
// The end index of `records.slice(0, pageSize)` for a JavaScript number pageSize: NaN is 0, a negative end
// counts back from the length, and the end is clamped to the length.
//
fn sliceEnd(length: usize, pageSize: f64) usize {
    if (std.math.isNan(pageSize)) {
        return 0;
    }
    const lengthValue: f64 = @floatFromInt(length);
    const end = @trunc(pageSize);
    if (end < 0) {
        return @intFromFloat(@max(lengthValue + end, 0));
    }
    return @intFromFloat(@min(end, lengthValue));
}

//
// JavaScript truthiness of an optional page id (TypeScript: `result.nextPageId && ...`).
//
fn isSet(pageId: ?[]const u8) bool {
    return pageId != null and pageId.?.len > 0;
}

//
// JavaScript truthiness of an optional field value (a missing field is undefined).
//
fn isTruthy(value: ?BsonValue) bool {
    const present = value orelse return false;
    return switch (present) {
        .number, .double => |number| number != 0 and !std.math.isNan(number),
        .int32 => |number| number != 0,
        .int64 => |number| number != 0,
        .string => |text| text.len > 0,
        .undefined, .null => false,
        .boolean => |boolean| boolean,
        else => true,
    };
}

//
// The time value of `new Date(value)` for a photo date: an ISO string is parsed, a Date keeps its time and a
// number is the time itself; anything else is an invalid date.
//
fn dateTime(allocator: std.mem.Allocator, value: BsonValue) !f64 {
    return switch (value) {
        .string => |text| js_date.parseDate(text),
        .date => |milliseconds| @floatFromInt(milliseconds),
        .number, .double => |number| number,
        .int32 => |number| @floatFromInt(number),
        .int64 => |number| @floatFromInt(number),
        else => js_date.parseDate(try js_value.toString(allocator, value)),
    };
}

//
// Formats `new Date(value).toLocaleDateString()`.
//
fn toLocaleDateString(allocator: std.mem.Allocator, value: BsonValue) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    try js_date.writeLocaleDateString(&writer.writer, try dateTime(allocator, value));
    return writer.written();
}

//
// Gets the properties of an asset (TypeScript: `record.properties`), or null when it is missing.
//
fn getProperties(record: IAsset) ?BsonDocument {
    const properties = record.get("properties") orelse return null;
    return switch (properties) {
        .document => |document| document,
        else => null,
    };
}

//
// Displays one page of records.
//
fn displayPage(allocator: std.mem.Allocator, records: []const IAsset, pageNumber: u32, pageSize: f64, encryptionHeaders: []const ?[]const u8) !void {
    _ = pageSize;
    log.info(try pc.bold(allocator, try pc.cyan(allocator, try std.fmt.allocPrint(allocator, "--- Page {d} ---", .{pageNumber}))));

    for (records, 0..) |record, recordIndex| {
        const photoDate = record.get("photoDate");
        const date = if (isTruthy(photoDate)) try toLocaleDateString(allocator, photoDate.?) else "Unknown";
        const fileSize = if (getProperties(record)) |properties| properties.get("fileSize") else null;
        const size = if (isTruthy(fileSize)) try format.formatBytes(allocator, try js_value.toNumber(allocator, fileSize.?), format.defaultFormatBytesOptions) else "Unknown";
        const width = record.get("width");
        const height = record.get("height");
        const dimensions = if (isTruthy(width) and isTruthy(height)) try std.fmt.allocPrint(allocator, "{s}\u{00D7}{s}", .{ try js_value.toString(allocator, width.?), try js_value.toString(allocator, height.?) }) else "";
        const encHeader = encryptionHeaders[recordIndex];
        const encStatus = if (encHeader) |header|
            try std.fmt.allocPrint(allocator, "encrypted (key: {x})", .{header})
        else
            "unencrypted";

        const origFileName = record.get("origFileName");
        const contentType = record.get("contentType");
        const fileName = if (isTruthy(origFileName)) try js_value.toString(allocator, origFileName.?) else "Unknown";
        const typeName = if (isTruthy(contentType)) try js_value.toString(allocator, contentType.?) else "Unknown";
        const dimensionsText = if (dimensions.len > 0) try std.fmt.allocPrint(allocator, " | {s}", .{dimensions}) else "";

        log.info(try std.fmt.allocPrint(allocator, "{s} {s}", .{ try pc.blue(allocator, try js_value.toString(allocator, record.get("_id").?)), try pc.green(allocator, fileName) }));
        log.info(try std.fmt.allocPrint(allocator, "  Date: {s} | Size: {s} | Type: {s}{s}", .{ date, size, typeName, dimensionsText }));
        log.info(try std.fmt.allocPrint(allocator, "  Encryption: {s}", .{encStatus}));

        const origPath = record.get("origPath");
        if (isTruthy(origPath)) {
            log.info(try std.fmt.allocPrint(allocator, "  Path: {s}", .{try js_value.toString(allocator, origPath.?)}));
        }

        log.info("");
    }
}

//
// Waits for a key press on stdin: Ctrl+C returns false, any other key true. stdin must be a TTY (TypeScript:
// `stdin.setRawMode` is not a function when it is not, so the command throws).
//
fn waitForUserInput(io: std.Io) !bool {
    const stdin = common.resolveInput(io, .{});
    if (!stdin.isTTY()) {
        return utils.errors.throwError("stdin.setRawMode is not a function", .{});
    }
    try stdin.setRawMode(true);

    // The first chunk of input is the key (TypeScript: the first 'data' event).
    stdin.reader.fillMore() catch |err| switch (err) {
        error.EndOfStream => {
            // Nothing keeps the process alive once stdin ends, so it exits with 0.
            try stdin.setRawMode(false);
            std.process.exit(0);
        },
        else => return err,
    };
    const key = stdin.reader.buffered();
    const isEnter = std.mem.eql(u8, key, "\r") or std.mem.eql(u8, key, "\n");
    const isCtrlC = std.mem.eql(u8, key, "\u{0003}");
    stdin.reader.tossBuffered();
    try stdin.setRawMode(false);

    if (isEnter) {
        // Enter key - continue to next page
        return true;
    }
    else if (isCtrlC) {
        // Ctrl+C - exit
        return false;
    }
    else {
        // Any other key - continue
        return true;
    }
}
