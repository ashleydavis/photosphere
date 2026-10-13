//
// Reads and writes a databases.toml as a background task.
//
// Nothing here is platform-specific: the handlers take the path of the config and reach it through
// the storage layer, the same one the databases themselves are read through. They exist because a
// caller with no filesystem access needs a way to reach the file, which is the mobile WebView's
// situation: it holds the database list but cannot open a file, so its reads and writes run in the
// embedded worker. Desktop has no such restriction and calls databases-config.zig directly.
//
// The on-disk layout comes from databases-config-format.zig, the same module desktop converts through,
// so a file written by either platform is readable by the other by construction rather than by two
// definitions being kept in step by hand.
//

const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const storage_zig = @import("storage-zig");
const task_queue_zig = @import("ziggy-core").task_queue;
const databases_config_format = @import("databases-config-format.zig");
const errors = utils.errors;
const toml = node_utils.toml;
const FileStorage = storage_zig.file_storage.FileStorage;
const ITaskContext = task_queue_zig.types.ITaskContext;
const IDatabaseEntry = databases_config_format.IDatabaseEntry;
const databaseEntryToToml = databases_config_format.databaseEntryToToml;
const tomlEntryToDatabaseEntry = databases_config_format.tomlEntryToDatabaseEntry;

//
// Input for the read-databases-config task.
// (Zig: the `= ""` default lets std.json parse data that leaves the key out, which the handler then refuses.)
//
pub const IReadDatabasesConfigData = struct {
    // Sandbox-relative path of databases.toml.
    configPath: []const u8 = "",
};

//
// Input for the write-databases-config task.
// (Zig: the `= ""` default lets std.json parse data that leaves the key out, which the handler then refuses. A missing
// lastDatabase is null.)
//
pub const IWriteDatabasesConfigData = struct {
    // Sandbox-relative path of databases.toml.
    configPath: []const u8 = "",

    // The configured databases to write.
    databases: []const IDatabaseEntry,

    // The recently opened database names to write, most recent first.
    recentDatabaseNames: []const []const u8,

    // Path of the database to open on the next start, or null when none should be.
    lastDatabase: ?[]const u8 = null,
};

//
// Result of the read-databases-config task.
// (Zig: the handler returns this as a JSON value, with the databases laid out as IDatabaseEntry and lastDatabase left out
// when it is null, as JSON leaves out an undefined property.)
//
pub const IReadDatabasesConfigResult = struct {
    // The configured databases, empty when the file does not exist yet.
    databases: []const IDatabaseEntry,

    // The recently opened database names, empty when the file does not exist yet.
    recentDatabaseNames: []const std.json.Value,

    // Path of the database to open on the next start, null when the file names none.
    lastDatabase: ?[]const u8 = null,
};

//
// Turns a database entry into the JSON it crosses the bridge as.
//
fn databaseEntryToJson(allocator: std.mem.Allocator, entry: IDatabaseEntry) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "name", .{
        .string = entry.name,
    });
    try object.put(allocator, "description", .{
        .string = entry.description,
    });
    try object.put(allocator, "path", .{
        .string = entry.path,
    });
    if (entry.origin) |origin| {
        try object.put(allocator, "origin", .{
            .string = origin,
        });
    }
    if (entry.s3Key) |s3Key| {
        try object.put(allocator, "s3Key", .{
            .string = s3Key,
        });
    }
    if (entry.encryptionKey) |encryptionKey| {
        try object.put(allocator, "encryptionKey", .{
            .string = encryptionKey,
        });
    }
    if (entry.geocodingKey) |geocodingKey| {
        try object.put(allocator, "geocodingKey", .{
            .string = geocodingKey,
        });
    }
    return .{
        .object = object,
    };
}

//
// Builds the JSON object the read-databases-config task returns.
//
fn readResultToJson(allocator: std.mem.Allocator, databases: []const IDatabaseEntry, recentDatabaseNames: []const std.json.Value, lastDatabase: ?[]const u8) !std.json.Value {
    var databasesArray: std.json.Array = .init(allocator);
    for (databases) |entry| {
        try databasesArray.append(try databaseEntryToJson(allocator, entry));
    }
    var recentArray: std.json.Array = .init(allocator);
    try recentArray.appendSlice(recentDatabaseNames);
    var result: std.json.ObjectMap = .empty;
    try result.put(allocator, "databases", .{
        .array = databasesArray,
    });
    try result.put(allocator, "recentDatabaseNames", .{
        .array = recentArray,
    });
    if (lastDatabase) |lastDatabasePath| {
        try result.put(allocator, "lastDatabase", .{
            .string = lastDatabasePath,
        });
    }
    return .{
        .object = result,
    };
}

//
// Handler for the read-databases-config task.
//
// A missing file returns empty lists, which is the state of a device that has registered no
// databases, and is what the app starts from on a fresh install.
// (Zig: the context is ignored. The task data and the result are JSON values holding
// IReadDatabasesConfigData and IReadDatabasesConfigResult.)
//
pub fn readDatabasesConfigHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    taskData: std.json.Value,
    context: ITaskContext,
) anyerror!std.json.Value {
    _ = context;
    // (Zig: reading the task data into the typed struct fails when configPath is not a string.
    // The failure is reported as a sentence, not a bare parser error name.)
    const data = std.json.parseFromValueLeaky(IReadDatabasesConfigData, allocator, taskData, .{
        .ignore_unknown_fields = true,
    }) catch {
        return errors.throwError("The read-databases-config task data is not valid: configPath must be a string", .{});
    };
    if (data.configPath.len == 0) {
        return errors.throwError("configPath is required", .{});
    }

    var storage = FileStorage.init("fs:");
    if (!try storage.fileExists(allocator, io, data.configPath)) {
        return readResultToJson(allocator, &.{}, &.{}, null);
    }

    const contents = try storage.read(allocator, io, data.configPath) orelse {
        return readResultToJson(allocator, &.{}, &.{}, null);
    };

    const parsed = try toml.parse(allocator, contents);
    const tomlObject = switch (parsed) {
        .object => |object| object,
        else => std.json.ObjectMap.empty,
    };
    var databases: std.ArrayList(IDatabaseEntry) = .empty;
    if (tomlObject.get("databases")) |tomlDatabases| {
        if (tomlDatabases == .array) {
            for (tomlDatabases.array.items) |tomlEntry| {
                try databases.append(allocator, tomlEntryToDatabaseEntry(tomlEntry));
            }
        }
    }
    var recentDatabaseNames: []const std.json.Value = &.{};
    if (tomlObject.get("recent_database_names")) |tomlRecentNames| {
        if (tomlRecentNames == .array) {
            recentDatabaseNames = tomlRecentNames.array.items;
        }
    }
    const lastDatabase = databases_config_format.stringProperty(tomlObject, "last_database");
    return readResultToJson(allocator, databases.items, recentDatabaseNames, lastDatabase);
}

//
// Handler for the write-databases-config task.
// (Zig: the context is ignored. The task data is a JSON value holding IWriteDatabasesConfigData, and
// the handler returns null.)
//
pub fn writeDatabasesConfigHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    taskData: std.json.Value,
    context: ITaskContext,
) anyerror!std.json.Value {
    _ = context;
    // (Zig: reading the task data into the typed struct fails when a field has the wrong type or is missing.
    // The failure is reported as a sentence, not a bare parser error name.)
    const data = std.json.parseFromValueLeaky(IWriteDatabasesConfigData, allocator, taskData, .{
        .ignore_unknown_fields = true,
    }) catch {
        return errors.throwError("The write-databases-config task data is not valid: configPath must be a string, databases a list of database entries and recentDatabaseNames a list of strings", .{});
    };
    if (data.configPath.len == 0) {
        return errors.throwError("configPath is required", .{});
    }

    const contents = try buildDatabasesConfigToml(allocator, data.databases, data.recentDatabaseNames, data.lastDatabase);
    var storage = FileStorage.init("fs:");
    try storage.write(allocator, io, data.configPath, "application/toml", contents);
    return .null;
}

//
// Prefix marking a database entry as a test fixture rather than one of the user's own.
//
// Entries carrying it are owned by the deploy script: it removes them and rewrites them freely.
// Anything without it is the user's and is never touched.
//
pub const TEST_DATABASE_PREFIX = "test-";

//
// Returns true when a name marks a test fixture.
// (Zig: ASCII letters only, as no non-ASCII letter can lower to the
// ASCII letters of the prefix.)
//
fn isTestDatabaseName(name: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(name, TEST_DATABASE_PREFIX);
}

//
// Adds a test database to the TOML text of a databases config, returning the new text.
//
// Used by the Android deploy script to register a
// fixture it has just copied onto a device, the same way a database is registered in
// ~/.config/photosphere/databases.toml on desktop. It is here, beside the read and write handlers,
// because it has to produce exactly the file they expect.
//
// The entry is named with the test prefix, so it reads as a test database in the app's list. Every
// other test entry is removed first, so old fixtures do not accumulate run after run. The user's own
// entries are never removed, reordered or edited, and neither are their recents.
//
// The fixture is registered, made most-recent and made last-opened in one move, because landing in
// the seeded database is the whole point of the deploy script: without the last two the app starts on
// the welcome screen and the fixture has to be found and tapped by hand. That overwrites whatever
// last_database the file named, which is the intent rather than a loss, since the caller has just
// asked for this database to be the one in front of them.
//
// Malformed TOML throws rather than being replaced: the file being unreadable is exactly when
// overwriting it would destroy a config that cannot be recovered.
// (Zig: takes the allocator that owns the returned text. A databases or recent_database_names value that is present but
// not a list, or a recent name that is not text, throws an error naming it.)
//
pub fn registerDatabaseInConfig(allocator: std.mem.Allocator, existingToml: []const u8, databasePath: []const u8) ![]const u8 {
    var tomlDatabases: []const std.json.Value = &.{};
    var recentDatabaseNames: []const std.json.Value = &.{};

    if (std.mem.trim(u8, existingToml, &std.ascii.whitespace).len > 0) {
        const parsed = try toml.parse(allocator, existingToml);
        const parsedObject = switch (parsed) {
            .object => |object| object,
            else => std.json.ObjectMap.empty,
        };
        if (parsedObject.get("databases")) |value| {
            if (value != .array) {
                return errors.throwError("databases in the databases config is not a list", .{});
            }
            tomlDatabases = value.array.items;
        }
        if (parsedObject.get("recent_database_names")) |value| {
            if (value != .array) {
                return errors.throwError("recent_database_names in the databases config is not a list", .{});
            }
            recentDatabaseNames = value.array.items;
        }
    }

    var databases: std.ArrayList(IDatabaseEntry) = .empty;
    for (tomlDatabases) |tomlEntry| {
        const entry = tomlEntryToDatabaseEntry(tomlEntry);
        if (!isTestDatabaseName(entry.name)) {
            try databases.append(allocator, entry);
        }
    }
    var recentNames: std.ArrayList([]const u8) = .empty;
    for (recentDatabaseNames) |recentName| {
        if (recentName != .string) {
            return errors.throwError("A recent database name in the databases config is not text", .{});
        }
        if (!isTestDatabaseName(recentName.string)) {
            try recentNames.append(allocator, recentName.string);
        }
    }

    const fixtureName = try std.mem.concat(allocator, u8, &.{ TEST_DATABASE_PREFIX, databasePath });
    try databases.append(allocator, .{
        .name = fixtureName,
        .description = "",
        .path = databasePath,
    });
    try recentNames.insert(allocator, 0, fixtureName);

    return buildDatabasesConfigToml(allocator, databases.items, recentNames.items, databasePath);
}

//
// Renders a whole databases config as the TOML text of a databases.toml, returning it rather than
// writing it anywhere.
//
// This is the same rendering writeDatabasesConfigHandler performs before it writes the file, factored
// out so a host-side script can produce a file the handlers read back exactly. The mobile smoke-test
// harness uses it to seed a device's database list from outside the app, which is how a mobile test establishes the state
// desktop tests establish by pre-writing ~/.config/photosphere/databases.toml.
// (Zig: takes the allocator that owns the returned text, and null stands for no lastDatabase.)
//
pub fn buildDatabasesConfigToml(allocator: std.mem.Allocator, databases: []const IDatabaseEntry, recentDatabaseNames: []const []const u8, lastDatabase: ?[]const u8) ![]const u8 {
    var recentArray: std.json.Array = .init(allocator);
    for (recentDatabaseNames) |recentName| {
        try recentArray.append(.{
            .string = recentName,
        });
    }
    var databasesArray: std.json.Array = .init(allocator);
    for (databases) |entry| {
        try databasesArray.append(try databaseEntryToToml(allocator, entry));
    }
    var tomlConfig: std.json.ObjectMap = .empty;
    try tomlConfig.put(allocator, "recent_database_names", .{
        .array = recentArray,
    });
    try tomlConfig.put(allocator, "databases", .{
        .array = databasesArray,
    });

    // Only written when there is one. A TOML serialiser given undefined either writes a key with no
    // value or throws, and an absent key is what "no database was open" has always looked like.
    if (lastDatabase) |lastDatabasePath| {
        try tomlConfig.put(allocator, "last_database", .{
            .string = lastDatabasePath,
        });
    }
    const text = try toml.stringify(allocator, .{
        .object = tomlConfig,
    });
    return std.mem.concat(allocator, u8, &.{ text, "\n" });
}
