const std = @import("std");
const node_api = @import("node-api-zig");
const node_utils = @import("node-utils-zig");
const utils = @import("utils-zig");
const errors = utils.errors;
const api = @import("api-zig");
const config_format = node_api.config_format;
const IConfigFile = config_format.IConfigFile;
const IAutoImportSource = api.auto_import_settings.IAutoImportSource;
const DEFAULT_AUTO_IMPORT_PAUSE_MS = api.auto_import_mobile.DEFAULT_AUTO_IMPORT_PAUSE_MS;
const DEFAULT_SYNC_PAUSE_MS = api.sync_settings.DEFAULT_SYNC_PAUSE_MS;

//
// Parses a JSON literal.
//
fn parseJson(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

//
// Turns a value into JSON text, for comparing documents (the order of the keys counts too).
//
fn toJson(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

//
// Asserts that two lists of sources are equal.
//
fn expectSources(expected: []const IAutoImportSource, actual: []const IAutoImportSource) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expectedSource, actualSource| {
        try std.testing.expectEqualStrings(expectedSource.sourceType(), actualSource.sourceType());
        switch (expectedSource) {
            .folder => |folder| {
                try std.testing.expectEqualStrings(folder.path, actualSource.folder.path);
                try std.testing.expectEqual(folder.recurse, actualSource.folder.recurse);
            },
            .@"device-album" => |album| {
                try std.testing.expectEqualStrings(album.albumId, actualSource.@"device-album".albumId);
            },
        }
    }
}

//
// Asserts that two optional strings are equal.
//
fn expectOptionalString(expected: ?[]const u8, actual: ?[]const u8) !void {
    if (expected) |expectedText| {
        try std.testing.expectEqualStrings(expectedText, actual.?);
        return;
    }
    try std.testing.expect(actual == null);
}

//
// Asserts that two configurations are equal.
//
fn expectConfigEqual(expected: IConfigFile, actual: IConfigFile) !void {
    try std.testing.expectEqual(expected.theme, actual.theme);
    try std.testing.expectEqual(expected.developerMode, actual.developerMode);
    try std.testing.expectEqual(expected.showFpsIndicator, actual.showFpsIndicator);
    if (expected.savedSearches) |expectedSearches| {
        try std.testing.expectEqual(expectedSearches.len, actual.savedSearches.?.len);
        for (expectedSearches, actual.savedSearches.?) |expectedSearch, actualSearch| {
            try std.testing.expectEqualStrings(expectedSearch, actualSearch);
        }
    }
    else {
        try std.testing.expect(actual.savedSearches == null);
    }
    try std.testing.expectEqual(expected.autoImportCleanupEnabled, actual.autoImportCleanupEnabled);

    try std.testing.expectEqual(expected.autoImport.settings.enabled, actual.autoImport.settings.enabled);
    try expectSources(expected.autoImport.settings.sources, actual.autoImport.settings.sources);
    try expectOptionalString(expected.autoImport.defaultDatabasePath, actual.autoImport.defaultDatabasePath);
    try std.testing.expectEqual(expected.autoImport.pauseBetweenRunsMs.integer, actual.autoImport.pauseBetweenRunsMs.integer);

    try std.testing.expectEqual(expected.sync.settings.enabled, actual.sync.settings.enabled);
    try std.testing.expectEqual(expected.sync.settings.onlyOnWifi, actual.sync.settings.onlyOnWifi);
    try expectOptionalString(expected.sync.databasePath, actual.sync.databasePath);
    try std.testing.expectEqual(expected.sync.pauseBetweenRunsMs.integer, actual.sync.pauseBetweenRunsMs.integer);
}












// Reading `type` off a null source throws, so a file with an empty list entry stops here with that message
// instead of that entry being dropped.



//
// A configuration with every field set, used by the round-trip tests.
//
fn fullConfig() IConfigFile {
    return .{
        .theme = .dark,
        .developerMode = true,
        .autoImport = .{
            .settings = .{
                .enabled = true,
                .sources = &.{
                    .{
                        .folder = .{
                            .path = "/home/user/Pictures",
                            .recurse = true,
                        },
                    },
                    .{
                        .@"device-album" = .{
                            .albumId = "all",
                        },
                    },
                },
            },
            .defaultDatabasePath = "/home/user/photos",
            .pauseBetweenRunsMs = .{
                .integer = 12345,
            },
        },
        .autoImportCleanupEnabled = true,
        .sync = .{
            .settings = .{
                .enabled = true,
                .onlyOnWifi = false,
            },
            .databasePath = "/home/user/photos",
            .pauseBetweenRunsMs = .{
                .integer = 54321,
            },
        },
        .showFpsIndicator = true,
        .savedSearches = &.{ "beach", "2024 birthday" },
    };
}




// Which sections are written says which features have been set, and a reader uses that to tell "nobody has chosen
// this" from "somebody switched it off". Writing every section every time would tell a fresh install that both had
// already been decided.





// Which sections a document carried, as distinct from the configuration, which fills every section from the defaults.
// A caller has to tell "nobody has chosen this" from "somebody switched it off", and the settings alone cannot say
// which, because both read as switched off.



// A hand-edited file can put a string or a list where a section belongs. Counting that as "these settings have been
// chosen" would leave a fresh install unseeded on the strength of a line that says nothing.









//
// An allocator whose first allocation fails and which then works as normal, so a test can tell code that returns an
// out of memory error from code that swallows it and carries on (std.testing.FailingAllocator keeps failing once it
// has failed, which cannot tell the two apart).
//
const FailsOnceAllocator = struct {
    // The allocator that does the work.
    child: std.mem.Allocator,

    // Whether the failure has been delivered.
    failed: bool = false,

    //
    // Gets the allocator.
    //
    fn allocator(self: *FailsOnceAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    //
    // Fails the first allocation, and passes on the rest.
    //
    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *FailsOnceAllocator = @ptrCast(@alignCast(context));
        if (!self.failed) {
            self.failed = true;
            return null;
        }
        return self.child.rawAlloc(length, alignment, return_address);
    }

    //
    // Passes a resize on.
    //
    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_length: usize, return_address: usize) bool {
        const self: *FailsOnceAllocator = @ptrCast(@alignCast(context));
        return self.child.rawResize(memory, alignment, new_length, return_address);
    }

    //
    // Passes a remap on.
    //
    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_length: usize, return_address: usize) ?[*]u8 {
        const self: *FailsOnceAllocator = @ptrCast(@alignCast(context));
        return self.child.rawRemap(memory, alignment, new_length, return_address);
    }

    //
    // Passes a free on.
    //
    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *FailsOnceAllocator = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, return_address);
    }
};

// Running out of memory is not a parse failure, so it comes back as the error it is and is not reported as a file that
// would not parse.
