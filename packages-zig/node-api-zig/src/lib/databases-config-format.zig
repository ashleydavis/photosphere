const std = @import("std");

//
// The on-disk shape of databases.toml and the conversions between it and the in-memory entry type.
//
// Shared by desktop (databases-config.ts, which owns ~/.config/photosphere/databases.toml) and
// mobile (databases-config.worker.ts, which owns the copy in the app's storage sandbox), so
// there is one definition of the file format rather than one per platform. Nothing here touches the
// filesystem, which is what lets it be bundled into the mobile worker.
//

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
// (Zig: the TOML on-disk shapes ITomlDatabaseEntry and ITomlDatabasesConfig (snake_case keys) are the std.json.Value
// objects produced by node-utils-zig's TOML parser, so they have no separate struct types.)
//

//
// Gets a string property of a TOML object (null when it is absent or not a string).
// (No TypeScript counterpart: TypeScript reads the property directly.)
//
pub fn stringProperty(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse {
        return null;
    };
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

//
// Converts a TOML-shaped database entry to the TypeScript IDatabaseEntry type.
// (Zig: a missing or non-string name, description or path reads as "".)
//
pub fn tomlEntryToDatabaseEntry(tomlEntry: std.json.Value) IDatabaseEntry {
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

// Not ported: databaseEntryToToml (only used when databases.toml is written, which psi replicate and
// psi verify do not do).
