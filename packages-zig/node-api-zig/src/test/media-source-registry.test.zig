const std = @import("std");
const utils = @import("utils-zig");
const api = @import("api-zig");
const node_api = @import("node-api-zig");
const registry = node_api.media_source_registry;
const IMediaItem = node_api.media_source.IMediaItem;
const IMediaSource = node_api.media_source.IMediaSource;
const IMediaSourceListPage = node_api.media_source.IMediaSourceListPage;
const IMediaSourceBuildOptions = registry.IMediaSourceBuildOptions;
const IAutoImportSource = api.auto_import_settings.IAutoImportSource;
const RandomUuidGenerator = utils.random_uuid_generator.RandomUuidGenerator;
const errors = utils.errors;

//
// A media source over a fixed list of items, so the registry can be tested without touching a filesystem or a
// photo library. (Zig: only what the registry tests use; the composite tests that use the rest are not ported.)
//
const ListMediaSource = struct {
    // Names the source (TypeScript: label).
    label: []const u8 = "folder",

    //
    // Gets the IMediaSource interface of this source.
    //
    fn mediaSource(self: *ListMediaSource) IMediaSource {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // The IMediaSource functions of this source.
    //
    const vtable: IMediaSource.VTable = .{
        .listPage = listPage,
        .openItem = openItem,
        .closeItem = closeItem,
        .deleteItems = deleteItems,
    };

    //
    // Lists nothing.
    //
    fn listPage(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, cursor: ?[]const u8, pageSize: usize) anyerror!IMediaSourceListPage {
        _ = ptr;
        _ = allocator;
        _ = io;
        _ = cursor;
        _ = pageSize;
        return .{
            .items = &.{},
            .nextCursor = null,
        };
    }

    //
    // Returns the item's path.
    //
    fn openItem(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, item: IMediaItem) anyerror![]const u8 {
        _ = ptr;
        _ = allocator;
        _ = io;
        return item.filePath;
    }

    //
    // Releases nothing.
    //
    fn closeItem(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, item: IMediaItem) anyerror!void {
        _ = ptr;
        _ = allocator;
        _ = io;
        _ = item;
    }

    //
    // Deletes nothing.
    //
    fn deleteItems(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, sourceIds: []const []const u8) anyerror!void {
        _ = ptr;
        _ = allocator;
        _ = io;
        _ = sourceIds;
    }
};

//
// The source the builders of these tests hand back. (Zig: a builder is a plain function, so what it closes over in
// TypeScript lives here.)
//
var builtSource: ListMediaSource = .{};

//
// The sources the last builder call was handed.
//
var handedOver: []const IAutoImportSource = &.{};

//
// The options the last builder call was handed.
//
var seenOptions: ?IMediaSourceBuildOptions = null;

//
// A builder that records what it was handed and returns builtSource.
//
fn recordingBuilder(allocator: std.mem.Allocator, sources: []const IAutoImportSource, options: IMediaSourceBuildOptions) anyerror!IMediaSource {
    handedOver = try allocator.dupe(IAutoImportSource, sources);
    seenOptions = options;
    return builtSource.mediaSource();
}

//
// The options every builder is handed. Nothing here cares what they are.
//
var buildGenerator: RandomUuidGenerator = .{};

//
// Makes the options every builder is handed.
//
fn buildOptions() IMediaSourceBuildOptions {
    return .{
        .sessionTempDir = "/tmp/session",
        .uuidGenerator = buildGenerator.uuidGenerator(),
    };
}

test "refuses to build from no sources at all" {
    registry.clearMediaSourceBuilders();
    defer registry.clearMediaSourceBuilders();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.Thrown, registry.buildMediaSource(arena.allocator(), &.{}, buildOptions()));
    try std.testing.expect(std.ascii.indexOfIgnoreCase(errors.lastErrorMessage(), "no automatic import sources") != null);
}

test "fails loudly for a source type nobody registered" {
    registry.clearMediaSourceBuilders();
    defer registry.clearMediaSourceBuilders();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_]IAutoImportSource{.{
        .@"device-album" = .{
            .albumId = "camera",
        },
    }};

    try std.testing.expectError(error.Thrown, registry.buildMediaSource(arena.allocator(), &sources, buildOptions()));
    try std.testing.expect(std.ascii.indexOfIgnoreCase(errors.lastErrorMessage(), "no media source builder is registered") != null);
}

test "a single registered type is built directly, without a composite" {
    registry.clearMediaSourceBuilders();
    defer registry.clearMediaSourceBuilders();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try registry.registerMediaSourceBuilder("folder", recordingBuilder);

    const source = try registry.buildMediaSource(arena.allocator(), &.{.{
        .folder = .{
            .path = "/photos",
            .recurse = true,
        },
    }}, buildOptions());

    try std.testing.expect(source.ptr == @as(*anyopaque, @ptrCast(&builtSource)));
}

test "every source of one type is handed to that type's builder at once" {
    registry.clearMediaSourceBuilders();
    defer registry.clearMediaSourceBuilders();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    handedOver = &.{};
    try registry.registerMediaSourceBuilder("folder", recordingBuilder);

    _ = try registry.buildMediaSource(arena.allocator(), &.{
        .{
            .folder = .{
                .path = "/one",
                .recurse = true,
            },
        },
        .{
            .folder = .{
                .path = "/two",
                .recurse = false,
            },
        },
    }, buildOptions());

    try std.testing.expectEqual(@as(usize, 2), handedOver.len);
}

test "the options are passed through to the builder" {
    registry.clearMediaSourceBuilders();
    defer registry.clearMediaSourceBuilders();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    seenOptions = null;
    try registry.registerMediaSourceBuilder("folder", recordingBuilder);
    const options = buildOptions();

    _ = try registry.buildMediaSource(arena.allocator(), &.{.{
        .folder = .{
            .path = "/photos",
            .recurse = true,
        },
    }}, options);

    try std.testing.expectEqualStrings(options.sessionTempDir, seenOptions.?.sessionTempDir);
    try std.testing.expect(options.uuidGenerator.ptr == seenOptions.?.uuidGenerator.ptr);
}

// Not ported: "two types are presented as one composite source" and the CompositeMediaSource tests (psi add only
// builds folder sources, so CompositeMediaSource is not ported; buildMediaSource throws when it would need one).
test "two source types need the composite, which is not ported" {
    registry.clearMediaSourceBuilders();
    defer registry.clearMediaSourceBuilders();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try registry.registerMediaSourceBuilder("folder", recordingBuilder);
    try registry.registerMediaSourceBuilder("device-album", recordingBuilder);

    try std.testing.expectError(error.Thrown, registry.buildMediaSource(arena.allocator(), &.{
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
    }, buildOptions()));
    try std.testing.expectEqualStrings("Not ported: CompositeMediaSource (psi add only builds folder sources).", errors.lastErrorMessage());
}
