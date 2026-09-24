const std = @import("std");
const builtin = @import("builtin");
const node_utils = @import("node-utils-zig");
const fs = node_utils.fs;
const process_env = node_utils.process_env;

//
// A database entry stored in databases.toml.
// The name field is the unique (case-insensitive) identifier for each entry.
//
pub const IDatabaseEntry = struct {
    // Human-readable display name.
    name: []const u8,

    // Optional description of this database.
    description: []const u8,

    // Absolute filesystem path (or S3 path) to the database directory.
    path: []const u8,

    // Optional origin string read from .db/config.json; refreshed each time the database is opened.
    origin: ?[]const u8 = null,

    // Vault secret name for S3 credentials.
    s3Key: ?[]const u8 = null,

    // Vault secret name for the encryption key pair.
    encryptionKey: ?[]const u8 = null,

    // Vault secret name for the geocoding API key.
    geocodingKey: ?[]const u8 = null,
};

//
// Configuration for the databases list, stored in ~/.config/photosphere/databases.toml.
//
pub const IDatabasesConfig = struct {
    //
    // Structured list of configured databases.
    //
    databases: []const IDatabaseEntry,

    //
    // Ordered list of recently opened database names (most recent first, max 5).
    //
    recentDatabaseNames: []const []const u8,
};

//
// (Zig: the TOML on-disk shapes ITomlDatabaseEntry and ITomlDatabasesConfig (snake_case keys) are the std.json.Value
// objects produced by node-utils-zig's TOML parser, so they have no separate struct types.)
//

//
// The directory holding the databases config.
// (TypeScript: the module constant CONFIG_DIR, which reads the environment when the module loads; Zig reads it on
// each call.)
//
fn CONFIG_DIR(allocator: std.mem.Allocator) ![]const u8 {
    if (process_env.getEnv("PHOTOSPHERE_CONFIG_DIR")) |configDir| {
        if (configDir.len > 0) {
            return configDir;
        }
    }
    const homeDir = process_env.getEnv(if (builtin.os.tag == .windows) "USERPROFILE" else "HOME") orelse "";
    return std.fs.path.join(allocator, &.{ homeDir, ".config", "photosphere" });
}

//
// The path of databases.toml (TypeScript: the module constant DATABASES_FILE).
//
fn DATABASES_FILE(allocator: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(allocator, &.{ try CONFIG_DIR(allocator), "databases.toml" });
}

//
// The path of the legacy databases.json (TypeScript: the module constant OLD_DATABASES_FILE).
//
fn OLD_DATABASES_FILE(allocator: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(allocator, &.{ try CONFIG_DIR(allocator), "databases.json" });
}

//
// Gets a string property of a JSON or TOML object (null when it is absent or not a string).
// (No TypeScript counterpart: TypeScript reads the property directly.)
//
fn stringProperty(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse {
        return null;
    };
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

//
// Gets an array property of a JSON or TOML object (null when it is absent or not an array, like Array.isArray).
// (No TypeScript counterpart.)
//
fn arrayProperty(object: std.json.ObjectMap, key: []const u8) ?[]const std.json.Value {
    const value = object.get(key) orelse {
        return null;
    };
    return switch (value) {
        .array => |array| array.items,
        else => null,
    };
}

//
// Gets the strings of an array of strings (non-string items are skipped). (No TypeScript counterpart.)
//
fn stringItems(allocator: std.mem.Allocator, items: []const std.json.Value) ![]const []const u8 {
    var strings: std.ArrayList([]const u8) = .empty;
    for (items) |item| {
        switch (item) {
            .string => |text| try strings.append(allocator, text),
            else => {},
        }
    }
    return strings.items;
}

//
// Converts a TOML-shaped database entry to the TypeScript IDatabaseEntry type.
// (Zig: a missing or non-string name, description or path reads as "".)
//
fn tomlEntryToDatabaseEntry(tomlEntry: std.json.Value) IDatabaseEntry {
    const object = switch (tomlEntry) {
        .object => |object| object,
        else => std.json.ObjectMap.empty,
    };
    var entry: IDatabaseEntry = .{
        .name = stringProperty(object, "name") orelse "",
        .description = stringProperty(object, "description") orelse "",
        .path = stringProperty(object, "path") orelse "",
    };
    if (stringProperty(object, "origin")) |origin| {
        entry.origin = origin;
    }
    if (stringProperty(object, "s3_key")) |s3Key| {
        entry.s3Key = s3Key;
    }
    if (stringProperty(object, "encryption_key")) |encryptionKey| {
        entry.encryptionKey = encryptionKey;
    }
    if (stringProperty(object, "geocoding_key")) |geocodingKey| {
        entry.geocodingKey = geocodingKey;
    }
    return entry;
}

//
// Converts a JSON database entry of the legacy databases.json (camelCase keys) to IDatabaseEntry.
// (No TypeScript counterpart: TypeScript uses the parsed JSON objects as they are.)
//
fn jsonEntryToDatabaseEntry(jsonEntry: std.json.Value) IDatabaseEntry {
    const object = switch (jsonEntry) {
        .object => |object| object,
        else => std.json.ObjectMap.empty,
    };
    return .{
        .name = stringProperty(object, "name") orelse "",
        .description = stringProperty(object, "description") orelse "",
        .path = stringProperty(object, "path") orelse "",
        .origin = stringProperty(object, "origin"),
        .s3Key = stringProperty(object, "s3Key"),
        .encryptionKey = stringProperty(object, "encryptionKey"),
        .geocodingKey = stringProperty(object, "geocodingKey"),
    };
}

//
// Converts a TypeScript IDatabaseEntry to the TOML on-disk shape.
//
fn databaseEntryToToml(allocator: std.mem.Allocator, entry: IDatabaseEntry) !std.json.Value {
    var tomlEntry: std.json.ObjectMap = .empty;
    try tomlEntry.put(allocator, "name", .{ .string = entry.name });
    try tomlEntry.put(allocator, "description", .{ .string = entry.description });
    try tomlEntry.put(allocator, "path", .{ .string = entry.path });
    if (entry.origin) |origin| {
        try tomlEntry.put(allocator, "origin", .{ .string = origin });
    }
    if (entry.s3Key) |s3Key| {
        try tomlEntry.put(allocator, "s3_key", .{ .string = s3Key });
    }
    if (entry.encryptionKey) |encryptionKey| {
        try tomlEntry.put(allocator, "encryption_key", .{ .string = encryptionKey });
    }
    if (entry.geocodingKey) |geocodingKey| {
        try tomlEntry.put(allocator, "geocoding_key", .{ .string = geocodingKey });
    }
    return .{ .object = tomlEntry };
}

//
// Converts a TOML-shaped config object to the TypeScript IDatabasesConfig type.
// Recognises only the new `recent_database_names` field; legacy `recent_database_paths`
// migration is handled separately in `loadDatabasesConfig`.
//
fn tomlToDatabasesConfig(allocator: std.mem.Allocator, toml: std.json.ObjectMap) !IDatabasesConfig {
    var databases: std.ArrayList(IDatabaseEntry) = .empty;
    if (arrayProperty(toml, "databases")) |tomlDatabases| {
        for (tomlDatabases) |tomlEntry| {
            try databases.append(allocator, tomlEntryToDatabaseEntry(tomlEntry));
        }
    }
    const recentDatabaseNames = if (arrayProperty(toml, "recent_database_names")) |names|
        try stringItems(allocator, names)
    else
        &[_][]const u8{};
    return .{ .databases = databases.items, .recentDatabaseNames = recentDatabaseNames };
}

//
// Converts the TypeScript IDatabasesConfig to the TOML on-disk shape.
//
fn databasesConfigToToml(allocator: std.mem.Allocator, config: IDatabasesConfig) !std.json.Value {
    var databases = std.json.Array.init(allocator);
    for (config.databases) |entry| {
        try databases.append(try databaseEntryToToml(allocator, entry));
    }
    var recentDatabaseNames = std.json.Array.init(allocator);
    for (config.recentDatabaseNames) |recentName| {
        try recentDatabaseNames.append(.{ .string = recentName });
    }
    var toml: std.json.ObjectMap = .empty;
    try toml.put(allocator, "databases", .{ .array = databases });
    try toml.put(allocator, "recent_database_names", .{ .array = recentDatabaseNames });
    return .{ .object = toml };
}

// Not ported: namesMatch (only used by the functions below that are not ported).

//
// Loads the databases configuration from disk.
// If the TOML file does not exist but an old JSON file does, migrates automatically.
// If the loaded TOML still uses the legacy `recent_database_paths` field, converts it
// to `recent_database_names` (resolving each path to its current entry's name; dropping
// paths that no longer match any entry) and rewrites the file.
// Returns a default config with an empty list if neither file exists.
//
pub fn loadDatabasesConfig(allocator: std.mem.Allocator, io: std.Io) !IDatabasesConfig {
    const databasesFile = try DATABASES_FILE(allocator);
    const oldDatabasesFile = try OLD_DATABASES_FILE(allocator);
    if (!fs.pathExists(io, databasesFile)) {
        if (fs.pathExists(io, oldDatabasesFile)) {
            const jsonValue = try fs.readJson(allocator, io, oldDatabasesFile);
            const jsonConfig = switch (jsonValue) {
                .object => |object| object,
                else => std.json.ObjectMap.empty,
            };
            var databases: std.ArrayList(IDatabaseEntry) = .empty;
            if (arrayProperty(jsonConfig, "databases")) |jsonDatabases| {
                for (jsonDatabases) |jsonEntry| {
                    try databases.append(allocator, jsonEntryToDatabaseEntry(jsonEntry));
                }
            }
            var recentDatabaseNames: []const []const u8 = undefined;
            if (arrayProperty(jsonConfig, "recentDatabaseNames")) |names| {
                recentDatabaseNames = try stringItems(allocator, names);
            }
            else if (arrayProperty(jsonConfig, "recentDatabasePaths")) |paths| {
                recentDatabaseNames = try recentPathsToNames(allocator, try stringItems(allocator, paths), databases.items);
            }
            else {
                recentDatabaseNames = &.{};
            }
            const migrated: IDatabasesConfig = .{ .databases = databases.items, .recentDatabaseNames = recentDatabaseNames };
            try saveDatabasesConfig(allocator, io, migrated);
            try fs.remove(io, oldDatabasesFile);
            return migrated;
        }
        return .{ .databases = &.{}, .recentDatabaseNames = &.{} };
    }

    const tomlValue = try fs.readToml(allocator, io, databasesFile);
    const toml = switch (tomlValue) {
        .object => |object| object,
        else => std.json.ObjectMap.empty,
    };

    // Legacy migration: convert recent_database_paths to recent_database_names and rewrite the file once.
    if (arrayProperty(toml, "recent_database_names") == null and arrayProperty(toml, "recent_database_paths") != null) {
        var databases: std.ArrayList(IDatabaseEntry) = .empty;
        if (arrayProperty(toml, "databases")) |tomlDatabases| {
            for (tomlDatabases) |tomlEntry| {
                try databases.append(allocator, tomlEntryToDatabaseEntry(tomlEntry));
            }
        }
        const migrated: IDatabasesConfig = .{
            .databases = databases.items,
            .recentDatabaseNames = try recentPathsToNames(allocator, try stringItems(allocator, arrayProperty(toml, "recent_database_paths").?), databases.items),
        };
        try saveDatabasesConfig(allocator, io, migrated);
        return migrated;
    }

    return tomlToDatabasesConfig(allocator, toml);
}

//
// Resolves the legacy recent-paths array into the new recent-names array by looking up
// each path in the current databases list. Paths that don't match any entry are dropped.
//
fn recentPathsToNames(allocator: std.mem.Allocator, recentPaths: []const []const u8, databases: []const IDatabaseEntry) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    for (recentPaths) |recentPath| {
        for (databases) |dbEntry| {
            if (std.mem.eql(u8, dbEntry.path, recentPath)) {
                try result.append(allocator, dbEntry.name);
                break;
            }
        }
    }
    return result.items;
}

//
// Saves the databases configuration to disk.
// (Zig: the TypeScript coercion of missing arrays to [] is not needed, because the slices always exist.)
//
pub fn saveDatabasesConfig(allocator: std.mem.Allocator, io: std.Io, config: IDatabasesConfig) !void {
    try fs.writeToml(allocator, io, try DATABASES_FILE(allocator), try databasesConfigToToml(allocator, config));
}

//
// Returns all configured database entries.
//
pub fn getDatabases(allocator: std.mem.Allocator, io: std.Io) ![]const IDatabaseEntry {
    const config = try loadDatabasesConfig(allocator, io);
    return config.databases;
}

// Not ported: findDatabase, addDatabaseEntry, updateDatabaseEntry, removeDatabaseEntry, getRecentDatabases,
// removeRecentDatabaseName, markDatabaseOpened (psi dbs, not psi replicate or psi verify).
