//
// Platform-neutral settings for automatic photo import.
//
// These are read by the auto-import task on every platform (CLI, desktop, mobile), so nothing in
// this file may depend on Node.js, Electron, Capacitor or the filesystem. The settings arrive from
// a config file that a user may have hand-edited, or that an older version of the app wrote, so
// `normaliseAutoImportSettings` is the only supported way to turn a stored blob into settings.
//

const std = @import("std");

//
// A folder on the local filesystem that is watched for new media. Used by the CLI and the desktop
// app, where the operating system exposes photo locations as ordinary directories.
//
pub const IFolderAutoImportSource = struct {
    // Absolute path of the folder to watch.
    path: []const u8,

    // Whether subfolders of this folder are watched as well.
    recurse: bool,
};

//
// An album in the device's photo library. Used by the mobile apps, where media is reached through
// MediaStore on Android and the Photos framework on iOS rather than through a filesystem path.
//
pub const IDeviceAlbumAutoImportSource = struct {
    // Platform-specific identifier of the album in the device photo library.
    albumId: []const u8,
};

// Not ported: ALL_DEVICE_MEDIA_ALBUM_ID (only the mobile apps use it).

//
// A place the auto-import task watches for new media.
// (Zig: a tagged union; the tag is the TypeScript `type` discriminator.)
//
pub const IAutoImportSource = union(enum) {
    // A source with `type: "folder"`.
    folder: IFolderAutoImportSource,

    // A source with `type: "device-album"`.
    @"device-album": IDeviceAlbumAutoImportSource,

    //
    // Gets the TypeScript `type` discriminator of the source.
    //
    pub fn sourceType(self: IAutoImportSource) []const u8 {
        return @tagName(self);
    }
};

//
// The settings that control automatic photo import.
//
pub const IAutoImportSettings = struct {
    // Whether automatic import runs at all. Everything else is ignored while this is off.
    enabled: bool,

    // The places that are watched for new media.
    sources: []const IAutoImportSource,
};

//
// Auto-import off, watching nothing.
//
pub const DEFAULT_AUTO_IMPORT_SETTINGS: IAutoImportSettings = .{
    .enabled = false,
    .sources = &.{},
};

//
// A source exactly as it was read from storage, before it has been checked. Every field is optional
// because nothing about a stored blob is guaranteed.
// (Zig: an unchecked source or settings blob is the std.json.Value it was read as.)
//
pub const IRawAutoImportSource = std.json.Value;

//
// A settings blob exactly as it was read from storage, before it has been checked.
//
pub const IRawAutoImportSettings = std.json.Value;

//
// True when the value is a boolean, so a stored string or number does not become a setting.
//
fn isBoolean(value: ?std.json.Value) bool {
    const present = value orelse {
        return false;
    };
    return present == .bool;
}

//
// True when the value is a non-empty string.
//
fn isNonEmptyString(value: ?std.json.Value) bool {
    const present = value orelse {
        return false;
    };
    return present == .string and present.string.len > 0;
}

//
// Turns one unchecked source into a usable source, or returns undefined when it is malformed and
// must be dropped.
//
pub fn normaliseAutoImportSource(rawSource: ?IRawAutoImportSource) ?IAutoImportSource {
    const source = rawSource orelse {
        return null;
    };
    if (source != .object) {
        return null;
    }
    const fields = source.object;

    const sourceTypeValue = fields.get("type");
    const isString = sourceTypeValue != null and sourceTypeValue.? == .string;

    if (isString and std.mem.eql(u8, sourceTypeValue.?.string, "folder")) {
        if (!isNonEmptyString(fields.get("path"))) {
            return null;
        }

        return .{
            .folder = .{
                .path = fields.get("path").?.string,
                .recurse = if (isBoolean(fields.get("recurse"))) fields.get("recurse").?.bool else true,
            },
        };
    }

    if (isString and std.mem.eql(u8, sourceTypeValue.?.string, "device-album")) {
        if (!isNonEmptyString(fields.get("albumId"))) {
            return null;
        }

        return .{
            .@"device-album" = .{
                .albumId = fields.get("albumId").?.string,
            },
        };
    }

    return null;
}

//
// Fills missing fields from the defaults and drops malformed sources, so a hand-edited or older
// settings blob cannot crash the auto-import task.
//
pub fn normaliseAutoImportSettings(allocator: std.mem.Allocator, rawSettings: ?IRawAutoImportSettings) !IAutoImportSettings {
    const settings = rawSettings orelse {
        return .{
            .enabled = DEFAULT_AUTO_IMPORT_SETTINGS.enabled,
            .sources = &.{},
        };
    };
    if (settings != .object) {
        // (Zig: a JSON null, which is `!rawSettings`, or a value that is not an object and so has no fields.)
        return .{
            .enabled = DEFAULT_AUTO_IMPORT_SETTINGS.enabled,
            .sources = &.{},
        };
    }
    const fields = settings.object;

    const rawSourcesValue = fields.get("sources");
    const rawSources: []const std.json.Value = if (rawSourcesValue != null and rawSourcesValue.? == .array) rawSourcesValue.?.array.items else &.{};
    var sources: std.ArrayList(IAutoImportSource) = .empty;
    for (rawSources) |rawSource| {
        if (normaliseAutoImportSource(rawSource)) |source| {
            try sources.append(allocator, source);
        }
    }

    return .{
        .enabled = if (isBoolean(fields.get("enabled"))) fields.get("enabled").?.bool else DEFAULT_AUTO_IMPORT_SETTINGS.enabled,
        .sources = sources.items,
    };
}

//
// Converts a source to the JSON object it is stored and queued as (TypeScript: the object itself).
// (No TypeScript counterpart.)
//
pub fn autoImportSourceToJson(allocator: std.mem.Allocator, source: IAutoImportSource) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "type", .{ .string = source.sourceType() });
    switch (source) {
        .folder => |folder| {
            try object.put(allocator, "path", .{ .string = folder.path });
            try object.put(allocator, "recurse", .{ .bool = folder.recurse });
        },
        .@"device-album" => |album| {
            try object.put(allocator, "albumId", .{ .string = album.albumId });
        },
    }
    return .{ .object = object };
}

//
// Converts a list of sources to the JSON array they are stored and queued as. (No TypeScript counterpart.)
//
pub fn autoImportSourcesToJson(allocator: std.mem.Allocator, sources: []const IAutoImportSource) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (sources) |source| {
        try array.append(try autoImportSourceToJson(allocator, source));
    }
    return .{ .array = array };
}

//
// Converts settings to the JSON object they are stored and queued as (TypeScript: the object itself).
// (No TypeScript counterpart.)
//
pub fn autoImportSettingsToJson(allocator: std.mem.Allocator, settings: IAutoImportSettings) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "enabled", .{ .bool = settings.enabled });
    try object.put(allocator, "sources", try autoImportSourcesToJson(allocator, settings.sources));
    return .{ .object = object };
}
