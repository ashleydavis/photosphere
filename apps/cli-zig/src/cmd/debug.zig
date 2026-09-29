const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const serialization_zig = @import("serialization-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const bdb = @import("bdb-zig");
const node_api = @import("node-api-zig");
const pc = @import("../lib/picocolors.zig");
const init_cmd = @import("../lib/init-cmd.zig");
const terminal_utils = @import("../lib/terminal-utils.zig");
const directory_picker = @import("../lib/directory-picker.zig");
const log = &utils.log.log;
const errorMessage = utils.errors.errorMessage;
const throwError = utils.errors.throwError;
const exit = node_utils.termination.exit;
const path = node_utils.path;
const loadDatabase = init_cmd.loadDatabase;
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;
const ICommandContext = init_cmd.ICommandContext;
const merkle_tree = merkle_tree_zig.merkle_tree;
const visualizeTree = merkle_tree_zig.visualize.visualizeTree;
const iterateLeaves = merkle_tree.iterateLeaves;
const MerkleNode = merkle_tree.MerkleNode;
const getItemInfo = merkle_tree.getItemInfo;
const loadDatabaseMerkleTree = bdb.merkle_tree.loadDatabaseMerkleTree;
const loadCollectionMerkleTree = bdb.merkle_tree.loadCollectionMerkleTree;
const loadShardMerkleTree = bdb.merkle_tree.loadShardMerkleTree;
const listShards = bdb.merkle_tree.listShards;
const hashRecord = bdb.merkle_tree.hashRecord;
const js_value = bdb.js_value;
const loadMerkleTree = node_api.tree.loadMerkleTree;
const buildFilesTree = node_api.tree.buildFilesTree;
const getDatabaseSummary = node_api.media_file_database.getDatabaseSummary;
const removeAsset = node_api.media_file_database.removeAsset;
const ensureSortIndex = node_api.media_file_database.ensureSortIndex;
const clearProgressMessage = terminal_utils.clearProgressMessage;
const writeProgress = terminal_utils.writeProgress;
const getDirectoryForCommand = directory_picker.getDirectoryForCommand;
const bson = serialization_zig.bson;
const BsonValue = bson.BsonValue;
const BsonDocument = bson.BsonDocument;
const jsonParse = serialization_zig.json_parse.jsonParse;
const writeIsoString = serialization_zig.js_date.writeIsoString;

//
// Options of the debug merkle-tree command (TypeScript: IDebugMerkleTreeCommandOptions extends IBaseCommandOptions).
// The base options are in `base`.
//
pub const IDebugMerkleTreeCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},

    // Shows the records of each shard.
    records: ?bool = null,

    // Shows every field of the records, without truncating long strings.
    all: ?bool = null,
};

//
// Helper function to truncate long string values and limit object fields for display
// (Zig: the TypeScript default parameter values 100, 5 and false are passed by the caller. A string is cut after
// maxLength UTF-16 code units, like `substring`. The objects whose own properties are not ported throw.)
//
fn truncateLongStrings(allocator: std.mem.Allocator, obj: BsonValue, maxLength: usize, maxFields: usize, showAllFields: bool) !BsonValue {
    if (obj == .string) {
        if (js_value.utf16Length(obj.string) > maxLength) {
            return .{
                .string = try std.mem.concat(allocator, u8, &.{ try utf16Substring(allocator, obj.string, maxLength), "..." }),
            };
        }
        return obj;
    }

    if (obj == .array) {
        const truncated = try allocator.alloc(BsonValue, obj.array.len);
        for (obj.array, 0..) |item, itemIndex| {
            truncated[itemIndex] = try truncateLongStrings(allocator, item, maxLength, maxFields, showAllFields);
        }
        return .{
            .array = truncated,
        };
    }

    if (obj != .null and std.mem.eql(u8, js_value.typeOf(obj), "object")) {
        const entries = try objectEntries(allocator, obj);
        var result: BsonDocument = .empty;

        // If showAllFields is true, use all entries; otherwise limit to maxFields
        const limitedEntries = if (showAllFields) entries else entries[0..@min(maxFields, entries.len)];

        for (limitedEntries) |entry| {
            try result.put(allocator, entry.key, try truncateLongStrings(allocator, entry.value, maxLength, maxFields, showAllFields));
        }

        // If there are more fields than the limit and we're not showing all, add an indicator
        if (!showAllFields and entries.len > maxFields) {
            try result.put(allocator, "...", .{
                .string = try std.fmt.allocPrint(allocator, "{d} more fields", .{entries.len - maxFields}),
            });
        }

        return .{
            .document = result,
        };
    }

    return obj;
}

//
// Returns the first `length` UTF-16 code units of a string, like `text.substring(0, length)`.
// (No TypeScript counterpart: JavaScript strings are UTF-16. Cut in the middle of a surrogate pair, the string ends
// with the lone high surrogate, held as WTF-8, which JSON.stringify writes as a `\u` escape.)
//
pub fn utf16Substring(allocator: std.mem.Allocator, text: []const u8, length: usize) ![]const u8 {
    var units: usize = 0;
    const view = try std.unicode.Utf8View.init(text);
    var iterator = view.iterator();
    while (units < length) {
        const codePoint = iterator.nextCodepoint() orelse {
            break;
        };
        const codePointUnits: usize = if (codePoint >= 0x10000) 2 else 1;
        if (units + codePointUnits > length) {
            const highSurrogate: u16 = @intCast(0xD800 + ((codePoint - 0x10000) >> 10));
            const start = iterator.i - 4;
            return std.mem.concat(allocator, u8, &.{ text[0..start], &.{ 0xED, 0xA0 | @as(u8, @intCast((highSurrogate >> 6) & 0x0F)), 0x80 | @as(u8, @intCast(highSurrogate & 0x3F)) } });
        }
        units += codePointUnits;
    }
    return text[0..iterator.i];
}

//
// Returns `Object.entries(value)` for an object (no TypeScript counterpart: the call is inline in
// truncateLongStrings). A document gives its fields, a Date has no own properties and a Long has low, high and
// unsigned. The other objects throw, because their own properties are not ported.
//
fn objectEntries(allocator: std.mem.Allocator, value: BsonValue) ![]const bson.BsonField {
    switch (value) {
        .document => |document| {
            return document.fields.items;
        },
        .date => {
            return &.{};
        },
        .int64 => {
            const long = try js_value.applyToJson(allocator, value);
            return long.document.fields.items;
        },
        else => {
            return throwError("Object.entries of a {s} is not ported.", .{@tagName(value)});
        },
    }
}

//
// Indents each line of a text (TypeScript: `text.split('\n').map(line => `${indent}${line}`).join('\n')`).
//
fn indentLines(allocator: std.mem.Allocator, text: []const u8, indent: []const u8) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var iterator = std.mem.splitScalar(u8, text, '\n');
    while (iterator.next()) |line| {
        try lines.append(allocator, try std.mem.concat(allocator, u8, &.{ indent, line }));
    }
    return std.mem.join(allocator, "\n", lines.items);
}

//
// Returns a line of repeated characters (TypeScript: `character.repeat(count)`).
//
fn repeat(allocator: std.mem.Allocator, character: u8, count: usize) ![]const u8 {
    const line = try allocator.alloc(u8, count);
    @memset(line, character);
    return line;
}

//
// Command to visualize all merkle trees in a media file database.
//
pub fn debugMerkleTreeCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, options: *IDebugMerkleTreeCommandOptions) !void {
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionId = context.sessionId;
    const loaded = try loadDatabase(allocator, io, options.base.db, &options.base, uuidGenerator, timestampProvider, sessionId, false);
    const assetStorage = loaded.assetStorage;
    const bsonDatabase = loaded.bsonDatabase;

    log.info("");
    log.info(try pc.bold(allocator, try pc.blue(allocator, "\u{1F333} Merkle Trees Visualization")));
    log.info("");

    // Get and display the aggregate root hash
    const summary = try getDatabaseSummary(allocator, io, assetStorage);
    log.info(try pc.cyan(allocator, "Aggregate Root Hash:"));
    log.info(try repeat(allocator, '=', 60));
    log.info(try pc.white(allocator, summary.fullHash));
    log.info("");

    // Show files merkle tree
    log.info(try pc.cyan(allocator, "Files Merkle Tree (.db/files.dat):"));
    log.info(try repeat(allocator, '=', 60));
    const filesTree = try loadMerkleTree(allocator, io, assetStorage);
    if (filesTree) |tree| {
        const filesVisualization = try visualizeTree(allocator, &tree);
        log.info(filesVisualization);
    }
    else {
        log.info(try pc.yellow(allocator, "No files merkle tree found."));
    }

    // Show BSON database merkle tree if it exists (v6: .db/bson)
    const databaseTree = try loadDatabaseMerkleTree(allocator, io, assetStorage, ".db/bson");

    if (databaseTree) |tree| {
        log.info("");
        log.info(try pc.cyan(allocator, "BSON Database Merkle Tree (.db/bson/db.dat):"));
        log.info(try repeat(allocator, '=', 60));
        const databaseVisualization = try visualizeTree(allocator, &tree);
        log.info(databaseVisualization);

        // Show all collection trees
        log.info("");
        log.info(try pc.cyan(allocator, "Collection Merkle Trees:"));
        log.info(try repeat(allocator, '=', 60));

        const collections = try bsonDatabase.collections(io);

        if (collections.len == 0) {
            log.info(try pc.yellow(allocator, "No collections found in database."));
        }
        else {
            for (collections) |collectionName| {
                const collectionTree = try loadCollectionMerkleTree(allocator, io, assetStorage, ".db/bson", collectionName);
                if (collectionTree) |loadedCollectionTree| {
                    log.info("");
                    log.info(try pc.cyan(allocator, try std.fmt.allocPrint(allocator, "Collection: {s}", .{collectionName})));
                    log.info(try repeat(allocator, '-', 60));
                    const collectionVisualization = try visualizeTree(allocator, &loadedCollectionTree);
                    log.info(collectionVisualization);
                }
                else {
                    log.info("");
                    log.info(try pc.cyan(allocator, try std.fmt.allocPrint(allocator, "Collection: {s}", .{collectionName})));
                    log.info(try pc.yellow(allocator, "  (no merkle tree found)"));
                }

                const collection = try bsonDatabase.collection(collectionName);

                // Show all shard trees for this collection
                const shardIds = try listShards(allocator, io, assetStorage, ".db/bson", collectionName);
                for (shardIds) |shardId| {
                    const shardTree = try loadShardMerkleTree(allocator, io, assetStorage, ".db/bson", collectionName, shardId);
                    if (shardTree) |loadedShardTree| {
                        log.info("");
                        log.info(try pc.cyan(allocator, try std.fmt.allocPrint(allocator, "  Shard: {s}", .{shardId})));
                        log.info(try std.mem.concat(allocator, u8, &.{ "  ", try repeat(allocator, '-', 58) }));
                        const shardVisualization = try visualizeTree(allocator, &loadedShardTree);
                        // Indent shard visualization
                        const indentedVisualization = try indentLines(allocator, shardVisualization, "  ");
                        log.info(indentedVisualization);
                    }
                    else {
                        log.info("");
                        log.info(try pc.yellow(allocator, try std.fmt.allocPrint(allocator, "    No shard tree found for shard {s}", .{shardId})));
                    }

                    // Show records if --records flag is set (even if no shard tree)
                    if (options.records orelse false) {
                        const shard = try collection.shard(shardId);

                        const shardRecords = try shard.records(io);
                        if (shardRecords.count() > 0) {
                            log.info("");
                            log.info(try pc.cyan(allocator, try std.fmt.allocPrint(allocator, "    Records in shard {s}:", .{shardId})));
                            for (shardRecords.keys(), shardRecords.values()) |recordId, record| {
                                // Compute hash for the record
                                const hashedItem = try hashRecord(allocator, io, record._id, record.fields);
                                const hashHex = try std.fmt.allocPrint(allocator, "{x}", .{hashedItem.hash});

                                log.info(try pc.white(allocator, try std.fmt.allocPrint(allocator, "      {s}:", .{recordId})));
                                log.info(try std.fmt.allocPrint(allocator, "        Hash: {s}", .{hashHex}));
                                // Truncate long strings unless --all is used
                                const recordValue: BsonValue = .{
                                    .document = try BsonDocument.fromFields(allocator, &.{
                                        .{
                                            .key = "_id",
                                            .value = .{
                                                .string = record._id,
                                            },
                                        },
                                        .{
                                            .key = "fields",
                                            .value = .{
                                                .document = record.fields,
                                            },
                                        },
                                        .{
                                            .key = "metadata",
                                            .value = .{
                                                .document = record.metadata,
                                            },
                                        },
                                    }),
                                };
                                const recordToDisplay = if (options.all orelse false) recordValue else try truncateLongStrings(allocator, recordValue, 100, 5, false);
                                const recordJson = try js_value.jsonStringifyIndented(allocator, recordToDisplay);
                                // Indent each line of the JSON
                                const indentedJson = try indentLines(allocator, recordJson, "        ");
                                log.info(indentedJson);
                            }
                        }
                        else {
                            log.info("");
                            log.info(try pc.yellow(allocator, try std.fmt.allocPrint(allocator, "    No records in shard {s}", .{shardId})));
                        }
                    }
                }
            }
        }
    }
    else {
        log.info("");
        log.info(try pc.yellow(allocator, "No BSON database merkle tree found (database may not have BSON collections yet)."));
    }

    log.info("");

    exit(io, 0);
}

//
// Options of the debug find-collisions command
// (TypeScript: IDebugFindCollisionsCommandOptions extends IBaseCommandOptions). The base options, which include the
// source database directory (`db`), are in `base`.
//
pub const IDebugFindCollisionsCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},

    //
    // Output JSON file path.
    //
    output: ?[]const u8 = null,
};

//
// Options of the debug find-duplicates command
// (TypeScript: IDebugFindDuplicatesCommandOptions extends IBaseCommandOptions). The base options, which include the
// source database directory (`db`, needed to read files), are in `base`.
//
pub const IDebugFindDuplicatesCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},

    //
    // Input JSON file path from find-collisions.
    //
    input: ?[]const u8 = null,

    //
    // Output JSON file path.
    //
    output: ?[]const u8 = null,
};

//
// Options of the debug remove-duplicates command
// (TypeScript: IDebugRemoveDuplicatesCommandOptions extends IBaseCommandOptions). The base options, which include the
// source database directory (`db`), are in `base`.
//
pub const IDebugRemoveDuplicatesCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},

    //
    // Input JSON file path from find-duplicates.
    //
    input: ?[]const u8 = null,
};

//
// The asset IDs found for one hash (TypeScript: an entry of the `hashMap` of debugFindCollisionsCommand).
//
const IHashAssetIds = struct {
    // The hash, in hex.
    hash: []const u8,

    // The asset IDs whose files have the hash.
    assetIds: []const []const u8,
};

//
// Sorts collisions by the number of asset IDs, most first
// (TypeScript: `(a, b) => b[1].length - a[1].length`, with the stable sort of Array.prototype.sort).
//
fn moreAssetIds(context: void, left: IHashAssetIds, right: IHashAssetIds) bool {
    _ = context;
    return left.assetIds.len > right.assetIds.len;
}

//
// Resolves an input or output path of the collision commands: an absolute path is used as it is and a relative path
// is joined to the database directory, while no path gives the default file in the database directory.
// (No TypeScript counterpart: each command writes the expression inline.)
//
fn resolveDatabaseFilePath(allocator: std.mem.Allocator, option: ?[]const u8, dbDirResolved: []const u8, defaultFileName: []const u8) ![]const u8 {
    if (option) |filePath| {
        if (filePath.len > 0) {
            return if (path.isAbsolute(filePath)) filePath else try path.join(allocator, &.{ dbDirResolved, filePath });
        }
    }
    return path.join(allocator, &.{ dbDirResolved, defaultFileName });
}

//
// What reading a JSON input file gives (TypeScript: the outcome of the try block that reads and parses the input of
// find-duplicates and remove-duplicates): the parsed JSON, or the message the catch block prints when it fails.
//
const IInputFileResult = union(enum) {
    // The parsed JSON.
    parsed: BsonValue,

    // The message of the error that reading or parsing the file threw.
    failure: []const u8,
};

//
// Reads and parses a JSON input file (TypeScript: `JSON.parse(await fs.readFile(inputPath, 'utf8'))`).
//
fn readInputFile(allocator: std.mem.Allocator, io: std.Io, inputPath: []const u8) !IInputFileResult {
    const inputContent = std.Io.Dir.cwd().readFileAlloc(io, inputPath, allocator, .unlimited) catch |err| {
        if (err == error.FileNotFound) {
            return .{
                .failure = try std.fmt.allocPrint(allocator, "ENOENT: no such file or directory, open '{s}'", .{inputPath}),
            };
        }
        return .{
            .failure = @errorName(err),
        };
    };
    const parsed = jsonParse(allocator, inputContent) catch |err| {
        return .{
            .failure = try std.fmt.allocPrint(allocator, "JSON Parse error: {s}", .{@errorName(err)}),
        };
    };
    return .{
        .parsed = parsed,
    };
}

//
// Gets the fields of a parsed JSON object (TypeScript: the `as CollisionsData` and `as DuplicatesData` casts, which
// check nothing). Anything but an object throws, because what TypeScript does with it is not ported.
//
fn expectObject(value: BsonValue, description: []const u8) ![]const bson.BsonField {
    if (value != .document) {
        return throwError("{s} that is not an object is not ported.", .{description});
    }
    return value.document.fields.items;
}

//
// Gets the elements of a parsed JSON array. Anything but an array throws, because what TypeScript does with it is
// not ported.
//
fn expectArray(value: BsonValue, description: []const u8) ![]const BsonValue {
    if (value != .array) {
        return throwError("{s} that is not an array is not ported.", .{description});
    }
    return value.array;
}

//
// Gets a property of a parsed JSON object (TypeScript: `object.name`), undefined when it is not there.
//
fn property(value: BsonValue, name: []const u8, description: []const u8) !BsonValue {
    const fields = try expectObject(value, description);
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, name)) {
            return field.value;
        }
    }
    return .undefined;
}

//
// Resolves the database directory of the collision commands: --db, or the directory picked for an existing
// database (TypeScript: the `if (dbDir === undefined)` block of each command).
//
fn resolveDbDir(allocator: std.mem.Allocator, io: std.Io, options: *const IBaseCommandOptions) ![]const u8 {
    const nonInteractive = options.yes orelse false;

    if (options.db) |db| {
        return db;
    }
    const cwd = if (options.cwd != null and options.cwd.?.len > 0) options.cwd.? else try std.process.currentPathAlloc(io, allocator);
    return getDirectoryForCommand(allocator, io, .existing, nonInteractive, cwd);
}

//
// Command that finds hash collisions (same hash, different asset IDs).
//
pub fn debugFindCollisionsCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, options: *IDebugFindCollisionsCommandOptions) !void {
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionId = context.sessionId;

    const dbDir = try resolveDbDir(allocator, io, &options.base);

    // Load the database
    const loaded = try loadDatabase(allocator, io, dbDir, &options.base, uuidGenerator, timestampProvider, sessionId, false);
    const assetStorage = loaded.assetStorage;
    const dbDirResolved = loaded.databaseDir;

    log.info("");
    log.info("Finding hash collisions in database:");
    log.info(try std.fmt.allocPrint(allocator, "  Database: {s}", .{try pc.cyan(allocator, dbDirResolved)}));
    log.info("");

    // Load merkle tree from the database
    writeProgress("Loading merkle tree...");
    const merkleTree = try loadMerkleTree(allocator, io, assetStorage);
    if (merkleTree == null or merkleTree.?.merkle == null) {
        clearProgressMessage();
        log.info(try pc.red(allocator, "Error: Failed to load database merkle tree"));
        exit(io, 1);
    }

    // Collect all leaf nodes from asset subdirectory and group by hash
    writeProgress("Walking merkle tree to find collisions...");
    var hashMap: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .empty; // hash -> array of asset IDs

    const merkleRoot = merkleTree.?.merkle.?;
    var leaves = iterateLeaves(MerkleNode, allocator, merkleRoot);
    while (try leaves.next()) |leaf| {
        const leafName = leaf.name orelse {
            continue;
        };
        if (leafName.len == 0) {
            continue;
        }

        // Only consider files in the asset subdirectory
        if (!std.mem.startsWith(u8, leafName, "asset/")) {
            continue;
        }

        // Extract asset ID from path (asset/{assetId})
        const assetId = leafName[6..];

        const hashHex = try std.fmt.allocPrint(allocator, "{x}", .{leaf.hash});
        const assetIds = try hashMap.getOrPut(allocator, hashHex);
        if (!assetIds.found_existing) {
            assetIds.value_ptr.* = .empty;
        }
        try assetIds.value_ptr.append(allocator, assetId);
    }

    clearProgressMessage();

    // Find collisions (hashes with more than one asset ID)
    var collisions: std.ArrayList(IHashAssetIds) = .empty;
    for (hashMap.keys(), hashMap.values()) |hash, assetIds| {
        if (assetIds.items.len > 1) {
            try collisions.append(allocator, .{
                .hash = hash,
                .assetIds = assetIds.items,
            });
        }
    }
    std.sort.block(IHashAssetIds, collisions.items, {}, moreAssetIds);

    // Build collisions data structure
    var collisionsData: BsonDocument = .empty;
    for (collisions.items) |collision| {
        var files: std.ArrayList(BsonValue) = .empty;
        for (collision.assetIds) |assetId| {
            const filePath = try std.fmt.allocPrint(allocator, "asset/{s}", .{assetId});
            const fileInfo = try getItemInfo(&merkleTree.?, filePath);
            if (fileInfo) |info| {
                var time: std.Io.Writer.Allocating = .init(allocator);
                try writeIsoString(&time.writer, info.lastModified);
                try files.append(allocator, .{
                    .document = try BsonDocument.fromFields(allocator, &.{
                        .{
                            .key = "assetId",
                            .value = .{
                                .string = assetId,
                            },
                        },
                        .{
                            .key = "size",
                            .value = .{
                                .number = @floatFromInt(info.length),
                            },
                        },
                        .{
                            .key = "time",
                            .value = .{
                                .string = time.written(),
                            },
                        },
                    }),
                });
            }
            else {
                try files.append(allocator, .{
                    .document = try BsonDocument.fromFields(allocator, &.{
                        .{
                            .key = "assetId",
                            .value = .{
                                .string = assetId,
                            },
                        },
                        .{
                            .key = "size",
                            .value = .{
                                .number = 0,
                            },
                        },
                        .{
                            .key = "time",
                            .value = .{
                                .string = "",
                            },
                        },
                    }),
                });
            }
        }
        try collisionsData.put(allocator, collision.hash, .{
            .array = files.items,
        });
    }

    // Write JSON file (default to collisions.json in database directory if relative path)
    const outputPath = try resolveDatabaseFilePath(allocator, options.output, dbDirResolved, "collisions.json");
    const collisionsJson = try js_value.jsonStringifyIndented(allocator, .{
        .document = collisionsData,
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = outputPath,
        .data = collisionsJson,
    });

    var totalAssetIds: usize = 0;
    for (collisions.items) |collision| {
        totalAssetIds += collision.assetIds.len;
    }

    log.info("");
    log.info(try pc.bold(allocator, try pc.blue(allocator, "\u{1F4CA} Summary")));
    log.info(try std.fmt.allocPrint(allocator, "Total collisions: {s}", .{try pc.cyan(allocator, try std.fmt.allocPrint(allocator, "{d}", .{collisions.items.len}))}));
    log.info(try std.fmt.allocPrint(allocator, "Total asset IDs in collisions: {s}", .{try pc.cyan(allocator, try std.fmt.allocPrint(allocator, "{d}", .{totalAssetIds}))}));
    log.info(try std.fmt.allocPrint(allocator, "Output file: {s}", .{try pc.cyan(allocator, outputPath)}));
    log.info("");

    exit(io, 0);
}

//
// The asset IDs of the files of one size (TypeScript: an entry of the `sizeGroups` map of
// debugFindDuplicatesCommand).
//
const ISizeGroup = struct {
    // The file size (a JavaScript number, compared like a Map key).
    size: f64,

    // The asset IDs of the files of that size.
    assetIds: std.ArrayList(BsonValue),
};

//
// Command that finds duplicate assets by comparing file content.
//
pub fn debugFindDuplicatesCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, options: *IDebugFindDuplicatesCommandOptions) !void {
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionId = context.sessionId;

    // Load the database first to get the directory for default paths
    const dbDir = try resolveDbDir(allocator, io, &options.base);

    const loaded = try loadDatabase(allocator, io, dbDir, &options.base, uuidGenerator, timestampProvider, sessionId, false);
    const dbDirResolved = loaded.databaseDir;

    // Get input file path (default to collisions.json in database directory)
    const inputPath = try resolveDatabaseFilePath(allocator, options.input, dbDirResolved, "collisions.json");

    const collisionsData = switch (try readInputFile(allocator, io, inputPath)) {
        .parsed => |parsed| parsed,
        .failure => |message| {
            log.info(try pc.red(allocator, try std.fmt.allocPrint(allocator, "Error: Failed to read input file {s}: {s}", .{ inputPath, message })));
            exit(io, 1);
        },
    };

    log.info("");
    log.info("Finding duplicate assets by comparing file sizes:");
    log.info(try std.fmt.allocPrint(allocator, "  Input file: {s}", .{try pc.cyan(allocator, inputPath)}));
    log.info(try std.fmt.allocPrint(allocator, "  Database: {s}", .{try pc.cyan(allocator, dbDirResolved)}));
    log.info("");

    // Group asset IDs by file size (files with same hash and same size are duplicates)
    var duplicatesData: BsonDocument = .empty;
    const hashes = try expectObject(collisionsData, "A collisions file");

    writeProgress("Grouping files by size...");
    for (hashes) |hashField| {
        const files = try expectArray(hashField.value, "A collisions entry");
        var sizeGroups: std.ArrayList(ISizeGroup) = .empty; // size -> asset IDs[]

        // Group asset IDs by their file size
        for (files) |file| {
            const sizeValue = try property(file, "size", "A collision file");
            if (sizeValue != .number) {
                return throwError("A collision file size that is not a number is not ported.", .{});
            }
            const size = sizeValue.number;
            var sizeGroup: ?*ISizeGroup = null;
            for (sizeGroups.items) |*existing| {
                // Map keys compare with SameValueZero: NaN matches NaN.
                if (existing.size == size or (std.math.isNan(existing.size) and std.math.isNan(size))) {
                    sizeGroup = existing;
                    break;
                }
            }
            if (sizeGroup == null) {
                try sizeGroups.append(allocator, .{
                    .size = size,
                    .assetIds = .empty,
                });
                sizeGroup = &sizeGroups.items[sizeGroups.items.len - 1];
            }
            try sizeGroup.?.assetIds.append(allocator, try property(file, "assetId", "A collision file"));
        }

        // Convert to output format (array of content groups)
        var contentGroups: std.ArrayList(BsonValue) = .empty;
        for (sizeGroups.items) |sizeGroup| {
            if (sizeGroup.assetIds.items.len > 0) {
                try contentGroups.append(allocator, .{
                    .document = try BsonDocument.fromFields(allocator, &.{
                        .{
                            .key = "assetIds",
                            .value = .{
                                .array = sizeGroup.assetIds.items,
                            },
                        },
                    }),
                });
            }
        }
        try duplicatesData.put(allocator, hashField.key, .{
            .array = contentGroups.items,
        });
    }
    clearProgressMessage();

    // Write JSON file (default to duplicates.json in database directory if relative path)
    const outputPath = try resolveDatabaseFilePath(allocator, options.output, dbDirResolved, "duplicates.json");
    const duplicatesJson = try js_value.jsonStringifyIndented(allocator, .{
        .document = duplicatesData,
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = outputPath,
        .data = duplicatesJson,
    });

    // Calculate statistics
    const totalCollisions = hashes.len;
    // True duplicates: hashes where all files have the same size (only one content group)
    var trueDuplicates: usize = 0;
    // Hash collisions: hashes where files have different sizes (multiple content groups)
    var hashCollisions: usize = 0;
    for (duplicatesData.fields.items) |field| {
        if (field.value.array.len == 1) {
            trueDuplicates += 1;
        }
        if (field.value.array.len > 1) {
            hashCollisions += 1;
        }
    }

    log.info("");
    log.info(try pc.bold(allocator, try pc.blue(allocator, "\u{1F4CA} Summary")));
    log.info(try std.fmt.allocPrint(allocator, "Total collisions: {s}", .{try pc.cyan(allocator, try std.fmt.allocPrint(allocator, "{d}", .{totalCollisions}))}));
    log.info(try std.fmt.allocPrint(allocator, "True duplicates (same content): {s}", .{try pc.green(allocator, try std.fmt.allocPrint(allocator, "{d}", .{trueDuplicates}))}));
    const hashCollisionsText = if (hashCollisions > 0) try pc.red(allocator, try std.fmt.allocPrint(allocator, "{d}", .{hashCollisions})) else try pc.green(allocator, "0");
    log.info(try std.fmt.allocPrint(allocator, "Hash collisions (different content): {s}", .{hashCollisionsText}));
    log.info(try std.fmt.allocPrint(allocator, "Output file: {s}", .{try pc.cyan(allocator, outputPath)}));
    log.info("");

    exit(io, 0);
}

//
// Command that removes duplicate assets based on content comparison results.
//
pub fn debugRemoveDuplicatesCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, options: *IDebugRemoveDuplicatesCommandOptions) !void {
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionId = context.sessionId;

    // Load the database first to get the directory for default paths
    const dbDir = try resolveDbDir(allocator, io, &options.base);

    const loaded = try loadDatabase(allocator, io, dbDir, &options.base, uuidGenerator, timestampProvider, sessionId, false);
    const dbDirResolved = loaded.databaseDir;

    // Get input file path (default to duplicates.json in database directory)
    const inputPath = try resolveDatabaseFilePath(allocator, options.input, dbDirResolved, "duplicates.json");

    // Load duplicates JSON file
    const duplicatesData = switch (try readInputFile(allocator, io, inputPath)) {
        .parsed => |parsed| parsed,
        .failure => |message| {
            log.info(try pc.red(allocator, try std.fmt.allocPrint(allocator, "Error: Failed to read input file {s}: {s}", .{ inputPath, message })));
            exit(io, 1);
        },
    };

    log.info("");
    log.info("Removing duplicate assets:");
    log.info(try std.fmt.allocPrint(allocator, "  Input file: {s}", .{try pc.cyan(allocator, inputPath)}));
    log.info(try std.fmt.allocPrint(allocator, "  Database: {s}", .{try pc.cyan(allocator, dbDirResolved)}));
    log.info("");

    // Collect all asset IDs to remove (keep first in each content group, remove the rest)
    var assetIdsToRemove: std.ArrayList([]const u8) = .empty;
    const hashes = try expectObject(duplicatesData, "A duplicates file");

    writeProgress("Analyzing duplicates...");
    for (hashes) |hashField| {
        const contentGroups = try expectArray(hashField.value, "A duplicates entry");
        for (contentGroups) |group| {
            const groupAssetIds = try expectArray(try property(group, "assetIds", "A content group"), "A content group's assetIds");
            // Keep the first asset ID, remove the rest
            if (groupAssetIds.len > 1) {
                for (groupAssetIds[1..]) |assetId| {
                    if (assetId != .string) {
                        return throwError("An asset ID that is not a string is not ported.", .{});
                    }
                    try assetIdsToRemove.append(allocator, assetId.string);
                }
            }
        }
    }
    clearProgressMessage();

    if (assetIdsToRemove.items.len == 0) {
        log.info(try pc.green(allocator, "No duplicate assets to remove."));
        log.info("");
        exit(io, 0);
    }

    const plural = if (assetIdsToRemove.items.len == 1) "" else "s";
    log.info(try pc.yellow(allocator, try std.fmt.allocPrint(allocator, "Found {d} duplicate asset{s} to remove", .{ assetIdsToRemove.items.len, plural })));
    log.info("");

    // Remove each duplicate asset
    writeProgress("Removing duplicate assets...");
    var removed: usize = 0;
    var errorCount: usize = 0;

    for (assetIdsToRemove.items, 0..) |assetId, index| {
        if (removeAsset(allocator, io, loaded.assetStorage, loaded.rawAssetStorage, sessionId, loaded.bsonDatabase, loaded.metadataCollection, assetId, false)) {
            removed += 1;
            if ((index + 1) % 10 == 0) {
                writeProgress(try std.fmt.allocPrint(allocator, "Removing duplicate assets... ({d}/{d})", .{ index + 1, assetIdsToRemove.items.len }));
            }
        }
        else |err| {
            errorCount += 1;
            log.verbose(try std.fmt.allocPrint(allocator, "Failed to remove asset {s}: {s}", .{ assetId, errorMessage(err) }));
        }
    }
    clearProgressMessage();

    log.info("");
    log.info(try pc.bold(allocator, try pc.blue(allocator, "\u{1F4CA} Summary")));
    log.info(try std.fmt.allocPrint(allocator, "Assets removed: {s}", .{try pc.green(allocator, try std.fmt.allocPrint(allocator, "{d}", .{removed}))}));
    if (errorCount > 0) {
        log.info(try std.fmt.allocPrint(allocator, "Errors: {s}", .{try pc.red(allocator, try std.fmt.allocPrint(allocator, "{d}", .{errorCount}))}));
    }
    log.info("");

    exit(io, 0);
}

//
// Command that deletes all sort indexes and rebuilds them completely.
//
pub fn debugBuildSortIndexCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, options: *IBaseCommandOptions) !void {
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionId = context.sessionId;
    const loaded = try loadDatabase(allocator, io, options.db, options, uuidGenerator, timestampProvider, sessionId, false);
    const metadataCollection = loaded.metadataCollection;
    const databaseDir = loaded.databaseDir;

    log.info("");
    log.info(try pc.bold(allocator, try pc.blue(allocator, "\u{1F528} Rebuilding Sort Indexes")));
    log.info(try std.fmt.allocPrint(allocator, "  Database: {s}", .{try pc.cyan(allocator, databaseDir)}));
    log.info("");

    // List all existing sort indexes
    writeProgress("Listing existing sort indexes...");
    const existingIndexes = try metadataCollection.sortIndexes(io);
    clearProgressMessage();

    if (existingIndexes.len > 0) {
        const existingPlural = if (existingIndexes.len == 1) "" else "es";
        log.info(try pc.yellow(allocator, try std.fmt.allocPrint(allocator, "Found {d} existing sort index{s}:", .{ existingIndexes.len, existingPlural })));
        for (existingIndexes) |index| {
            log.info(try std.fmt.allocPrint(allocator, "  - {s} ({s})", .{ index.fieldName, @tagName(index.direction) }));
        }
        log.info("");

        // Delete all existing sort indexes
        writeProgress("Deleting existing sort indexes...");
        var deletedCount: usize = 0;
        for (existingIndexes) |index| {
            const sortIndex = try metadataCollection.sortIndex(index.fieldName, index.direction);
            const deleted = try sortIndex.drop(io);
            if (deleted) {
                deletedCount += 1;
            }
        }
        clearProgressMessage();

        const deletedPlural = if (deletedCount == 1) "" else "es";
        log.info(try pc.green(allocator, try std.fmt.allocPrint(allocator, "Deleted {d} sort index{s}.", .{ deletedCount, deletedPlural })));
        log.info("");
    }
    else {
        log.info(try pc.yellow(allocator, "No existing sort indexes found."));
        log.info("");
    }

    // Rebuild the expected sort indexes
    log.info(try pc.cyan(allocator, "Rebuilding sort indexes..."));
    log.info("");

    writeProgress("Rebuilding hash index (asc)...");
    try ensureSortIndex(io, metadataCollection);
    clearProgressMessage();

    log.info(try pc.green(allocator, "\u{2705} Sort indexes rebuilt successfully."));
    log.info("");
    log.info(try pc.bold(allocator, "Rebuilt indexes:"));
    log.info("  - hash (asc, string)");
    log.info("  - photoDate (desc, date)");
    log.info("");

    exit(io, 0);
}

//
// Writes the progress of buildFilesTree every 50 files
// (TypeScript: the `(count) => { if (count % 50 === 0) { writeProgress(...) } }` arrow function).
//
fn onFilesHashed(context: ?*anyopaque, count: u64) void {
    _ = context;
    if (count % 50 == 0) {
        var buffer: [64]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "Hashed {d} files...", .{count}) catch unreachable;
        writeProgress(message);
    }
}

//
// Rebuilds the files merkle tree (.db/files.dat) from the actual files on storage.
// Walks storage, hashes each file (logical/decrypted content when encrypted), and builds
// a new tree with logical hash, length, and lastModified per file. This is the single
// source of truth for "rebuild tree from files".
//
pub fn debugBuildFilesTreeCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, options: *IBaseCommandOptions) !void {
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionId = context.sessionId;

    const dbDir = try resolveDbDir(allocator, io, options);

    const loaded = try loadDatabase(allocator, io, dbDir, options, uuidGenerator, timestampProvider, sessionId, false);
    const dbDirResolved = loaded.databaseDir;

    log.info("");
    log.info(try pc.bold(allocator, try pc.blue(allocator, "Rebuilding files merkle tree from storage")));
    log.info(try std.fmt.allocPrint(allocator, "  Database: {s}", .{try pc.cyan(allocator, dbDirResolved)}));
    log.info("");

    const result = try buildFilesTree(allocator, io, loaded.assetStorage, .{
        .context = null,
        .function = onFilesHashed,
    }, uuidGenerator);
    clearProgressMessage();

    log.info(try pc.green(allocator, try std.fmt.allocPrint(allocator, "Rebuilt files merkle tree: {d} files.", .{result.fileCount})));
    log.info("");
    exit(io, 0);
}
