const std = @import("std");
const api_zig = @import("api-zig");
const auto_import_settings = api_zig.auto_import_settings;
const DEFAULT_AUTO_IMPORT_SETTINGS = auto_import_settings.DEFAULT_AUTO_IMPORT_SETTINGS;
const IAutoImportSettings = auto_import_settings.IAutoImportSettings;
const IAutoImportSource = auto_import_settings.IAutoImportSource;
const normaliseAutoImportSettings = auto_import_settings.normaliseAutoImportSettings;
const normaliseAutoImportSource = auto_import_settings.normaliseAutoImportSource;
const autoImportSettingsToJson = auto_import_settings.autoImportSettingsToJson;

//
// Parses a JSON literal.
//
fn parseJson(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

//
// Asserts that two sources are equal.
//
fn expectSource(expected: IAutoImportSource, actual: IAutoImportSource) !void {
    try std.testing.expectEqualStrings(expected.sourceType(), actual.sourceType());
    switch (expected) {
        .folder => |folder| {
            try std.testing.expectEqualStrings(folder.path, actual.folder.path);
            try std.testing.expectEqual(folder.recurse, actual.folder.recurse);
        },
        .@"device-album" => |album| {
            try std.testing.expectEqualStrings(album.albumId, actual.@"device-album".albumId);
        },
    }
}

//
// Asserts that two lists of sources are equal.
//
fn expectSources(expected: []const IAutoImportSource, actual: []const IAutoImportSource) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expectedSource, actualSource| {
        try expectSource(expectedSource, actualSource);
    }
}

//
// Asserts that two settings are equal.
//
fn expectSettings(expected: IAutoImportSettings, actual: IAutoImportSettings) !void {
    try std.testing.expectEqual(expected.enabled, actual.enabled);
    try expectSources(expected.sources, actual.sources);
}

test "returns the defaults when there is nothing stored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try expectSettings(DEFAULT_AUTO_IMPORT_SETTINGS, try normaliseAutoImportSettings(allocator, null));
    try expectSettings(DEFAULT_AUTO_IMPORT_SETTINGS, try normaliseAutoImportSettings(allocator, .null));
}

test "leaves valid settings untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const stored: IAutoImportSettings = .{
        .enabled = true,
        .sources = &.{
            .{
                .folder = .{
                    .path = "/home/someone/Pictures",
                    .recurse = false,
                },
            },
            .{
                .@"device-album" = .{
                    .albumId = "camera-roll",
                },
            },
        },
    };

    try expectSettings(stored, try normaliseAutoImportSettings(allocator, try autoImportSettingsToJson(allocator, stored)));
}

test "fills missing fields from the defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const normalised = try normaliseAutoImportSettings(allocator, try parseJson(allocator, "{\"enabled\": true}"));

    try expectSettings(.{
        .enabled = true,
        .sources = &.{},
    }, normalised);
}

test "replaces booleans that are not booleans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const normalised = try normaliseAutoImportSettings(allocator, try parseJson(allocator, "{\"enabled\": \"yes\"}"));

    try std.testing.expectEqual(false, normalised.enabled);
}

test "drops malformed sources and keeps the good ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // (JSON has no undefined, so the list ends with a null.)
    const stored = try parseJson(allocator,
        \\{
        \\    "sources": [
        \\        { "type": "folder", "path": "/photos", "recurse": true },
        \\        { "type": "folder" },
        \\        { "type": "folder", "path": "" },
        \\        { "type": "device-album", "albumId": "camera" },
        \\        { "type": "device-album" },
        \\        { "type": "carrier-pigeon", "path": "/photos" },
        \\        null,
        \\        null
        \\    ]
        \\}
    );

    try expectSources(&.{
        .{
            .folder = .{
                .path = "/photos",
                .recurse = true,
            },
        },
        .{
            .@"device-album" = .{
                .albumId = "camera",
            },
        },
    }, (try normaliseAutoImportSettings(allocator, stored)).sources);
}

test "drops a sources field that is not a list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const stored = try parseJson(allocator, "{\"sources\": \"/photos\"}");

    try expectSources(&.{}, (try normaliseAutoImportSettings(allocator, stored)).sources);
}

test "a folder source with no recurse flag recurses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try expectSource(.{
        .folder = .{
            .path = "/photos",
            .recurse = true,
        },
    }, normaliseAutoImportSource(try parseJson(allocator, "{\"type\": \"folder\", \"path\": \"/photos\"}")).?);
}

test "a folder source keeps an explicit recurse flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try expectSource(.{
        .folder = .{
            .path = "/photos",
            .recurse = false,
        },
    }, normaliseAutoImportSource(try parseJson(allocator, "{\"type\": \"folder\", \"path\": \"/photos\", \"recurse\": false}")).?);
}

test "an unrecognised source type is dropped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expect(normaliseAutoImportSource(try parseJson(allocator, "{\"type\": \"album\", \"albumId\": \"camera\"}")) == null);
    try std.testing.expect(normaliseAutoImportSource(null) == null);
    try std.testing.expect(normaliseAutoImportSource(.null) == null);
}
