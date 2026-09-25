const std = @import("std");
const node_utils = @import("node-utils-zig");
const databases_config_format = @import("databases-config-format.zig");
const fs = node_utils.fs;
const tomlEntryToDatabaseEntry = databases_config_format.tomlEntryToDatabaseEntry;

// Re-exported: this module has always been where the codebase imports the entry type from. The
// definition now lives with the file format, which mobile shares.
pub const IDatabaseEntry = databases_config_format.IDatabaseEntry;

//
// Configuration for the databases list, stored in ~/.config/photosphere/databases.toml.
//
pub const IDatabasesConfig = struct {
    //
    // Structured list of configured databases.
    //
    databases: []const IDatabaseEntry,

    //
    // Ordered list of recently opened database names, most recent first, capped at
    // MAX_RECENT_DATABASES.
    //
    recentDatabaseNames: []const []const u8,

    //
    // Path of the database to reopen on the next launch; absent when none is open.
    //
    lastDatabase: ?[]const u8 = null,
};

//
// The file holding the list of databases, in the Photosphere data directory.
//
// getConfigDir works out where that is per platform: under the user's home directory on desktop and
// on the CLI, and the app's storage sandbox on a device, which has no home directory.
//
// Getting this wrong is not harmless. It previously always appended ".config/photosphere", so on a
// device the lookup resolved to a file that cannot exist, every credential lookup found an empty
// list, and S3 databases failed with "Region is missing" while working perfectly on desktop.
//
// (TypeScript: the module constant DATABASES_FILE, which reads the environment when the module loads; Zig reads it on
// each call.)
//
fn DATABASES_FILE(allocator: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(allocator, &.{ try fs.getConfigDir(allocator), "databases.toml" });
}

// Not ported: getDatabasesConfigPath, MAX_RECENT_DATABASES (psi dbs, not psi replicate or psi verify).

//
// Gets an array property of a TOML object (null when it is absent or not an array, like Array.isArray).
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
// Converts a TOML-shaped config object to the TypeScript IDatabasesConfig type.
//
pub fn tomlToDatabasesConfig(allocator: std.mem.Allocator, toml: std.json.ObjectMap) !IDatabasesConfig {
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
    var config: IDatabasesConfig = .{ .databases = databases.items, .recentDatabaseNames = recentDatabaseNames };
    if (databases_config_format.stringProperty(toml, "last_database")) |lastDatabase| {
        config.lastDatabase = lastDatabase;
    }
    return config;
}

// Not ported: databasesConfigToToml, namesMatch (only used when databases.toml is written, which psi replicate
// and psi verify do not do).

//
// Loads the databases configuration from disk.
// Returns a default config with an empty list if the file does not exist.
//
pub fn loadDatabasesConfig(allocator: std.mem.Allocator, io: std.Io) !IDatabasesConfig {
    const databasesFile = try DATABASES_FILE(allocator);
    if (!fs.pathExists(io, databasesFile)) {
        return .{ .databases = &.{}, .recentDatabaseNames = &.{} };
    }

    const tomlValue = try fs.readToml(allocator, io, databasesFile);
    const toml = switch (tomlValue) {
        .object => |object| object,
        else => std.json.ObjectMap.empty,
    };
    return tomlToDatabasesConfig(allocator, toml);
}

// Not ported: updateDatabasesConfig (psi dbs, not psi replicate or psi verify).

//
// Returns all configured database entries.
//
pub fn getDatabases(allocator: std.mem.Allocator, io: std.Io) ![]const IDatabaseEntry {
    const config = try loadDatabasesConfig(allocator, io);
    return config.databases;
}

// Not ported: findDatabase, addDatabaseEntry, updateDatabaseEntry, removeDatabaseEntry, getRecentDatabases,
// removeRecentDatabaseName, markDatabaseOpened, getLastDatabase, setLastDatabase (psi dbs, not psi replicate or
// psi verify).
