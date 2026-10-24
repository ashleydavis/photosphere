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
// photo library.
//
const ListMediaSource = struct {
    // Names the source.
    label: []const u8 = "folder",

    // The names of the items the source offers, in listing order.
    itemNames: []const []const u8 = &.{},

    // The source ids this source was asked to delete, one entry per request, in order.
    deleteRequests: std.ArrayList([]const []const u8) = .empty,

    // The items exported through this source, in order.
    exported: std.ArrayList([]const u8) = .empty,

    // The items released through this source, in order.
    released: std.ArrayList([]const u8) = .empty,

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
    // Lists the page of items that follows the cursor, which is the source id of the last item of the page before.
    //
    fn listPage(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, cursor: ?[]const u8, pageSize: usize) anyerror!IMediaSourceListPage {
        _ = io;
        const self: *ListMediaSource = @ptrCast(@alignCast(ptr));
        var items: std.ArrayList(IMediaItem) = .empty;
        for (self.itemNames) |name| {
            try items.append(allocator, .{
                .sourceId = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.label, name }),
                .filePath = try std.fmt.allocPrint(allocator, "/{s}/{s}", .{ self.label, name }),
                .displayName = name,
                .contentType = "image/jpeg",
                .size = 100,
                .createdAt = 1767225600000,
            });
        }

        var startIndex: usize = 0;
        if (cursor) |cursorSourceId| {
            for (items.items, 0..) |item, index| {
                if (std.mem.eql(u8, item.sourceId, cursorSourceId)) {
                    startIndex = index + 1;
                    break;
                }
            }
        }
        const endOfPage = @min(startIndex + pageSize, items.items.len);
        const page = items.items[startIndex..endOfPage];
        return .{
            .items = page,
            .nextCursor = if (endOfPage < items.items.len and page.len > 0) page[page.len - 1].sourceId else null,
        };
    }

    //
    // Records the export and returns the item's path.
    //
    fn openItem(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, item: IMediaItem) anyerror![]const u8 {
        _ = io;
        const self: *ListMediaSource = @ptrCast(@alignCast(ptr));
        try self.exported.append(allocator, item.sourceId);
        return item.filePath;
    }

    //
    // Records the release.
    //
    fn closeItem(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, item: IMediaItem) anyerror!void {
        _ = io;
        const self: *ListMediaSource = @ptrCast(@alignCast(ptr));
        try self.released.append(allocator, item.sourceId);
    }

    //
    // Records the request and deletes nothing.
    //
    fn deleteItems(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, sourceIds: []const []const u8) anyerror!void {
        _ = io;
        const self: *ListMediaSource = @ptrCast(@alignCast(ptr));
        try self.deleteRequests.append(allocator, try allocator.dupe([]const u8, sourceIds));
    }
};

//
// The source the builders of these tests hand back. A builder is a plain function, so what it needs lives here.
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
// The source the folder builder hands back in the composite test.
//
var folderSource: ListMediaSource = .{
    .label = "folder",
    .itemNames = &.{"a.jpg"},
};

//
// The source the album builder hands back in the composite test.
//
var albumSource: ListMediaSource = .{
    .label = "album",
    .itemNames = &.{"b.jpg"},
};

//
// A builder that returns folderSource.
//
fn folderBuilder(allocator: std.mem.Allocator, sources: []const IAutoImportSource, options: IMediaSourceBuildOptions) anyerror!IMediaSource {
    _ = allocator;
    _ = sources;
    _ = options;
    return folderSource.mediaSource();
}

//
// A builder that returns albumSource.
//
fn albumBuilder(allocator: std.mem.Allocator, sources: []const IAutoImportSource, options: IMediaSourceBuildOptions) anyerror!IMediaSource {
    _ = allocator;
    _ = sources;
    _ = options;
    return albumSource.mediaSource();
}

//
// Drains every page of a source into one list.
//
fn listAll(allocator: std.mem.Allocator, source: IMediaSource, pageSize: usize) ![]IMediaItem {
    var items: std.ArrayList(IMediaItem) = .empty;
    var cursor: ?[]const u8 = null;
    var pages: usize = 0;
    while (true) {
        const page = try source.listPage(allocator, std.testing.io, cursor, pageSize);
        try items.appendSlice(allocator, page.items);
        cursor = page.nextCursor;
        pages += 1;
        if (pages > 50) {
            return error.PagingDidNotTerminate;
        }
        if (cursor == null) {
            break;
        }
    }
    return items.items;
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
        .nativeCaller = null,
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

test "two types are presented as one composite source" {
    registry.clearMediaSourceBuilders();
    defer registry.clearMediaSourceBuilders();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try registry.registerMediaSourceBuilder("folder", folderBuilder);
    try registry.registerMediaSourceBuilder("device-album", albumBuilder);

    const source = try registry.buildMediaSource(arena.allocator(), &.{
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
    }, buildOptions());

    try std.testing.expect(source.ptr != @as(*anyopaque, @ptrCast(&folderSource)));
    try std.testing.expect(source.ptr != @as(*anyopaque, @ptrCast(&albumSource)));
    const items = try listAll(arena.allocator(), source, 10);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("0#folder/a.jpg", items[0].sourceId);
    try std.testing.expectEqualStrings("1#album/b.jpg", items[1].sourceId);
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

test "composite lists both children, one after the other" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var first: ListMediaSource = .{
        .label = "first",
        .itemNames = &.{ "a.jpg", "b.jpg" },
    };
    var second: ListMediaSource = .{
        .label = "second",
        .itemNames = &.{"c.jpg"},
    };
    var composite = registry.CompositeMediaSource.init(&.{ first.mediaSource(), second.mediaSource() });

    const items = try listAll(arena.allocator(), composite.mediaSource(), 10);

    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("a.jpg", items[0].displayName);
    try std.testing.expectEqualStrings("b.jpg", items[1].displayName);
    try std.testing.expectEqualStrings("c.jpg", items[2].displayName);
}

test "composite pages across the boundary between children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var first: ListMediaSource = .{
        .label = "first",
        .itemNames = &.{ "a.jpg", "b.jpg", "c.jpg" },
    };
    var second: ListMediaSource = .{
        .label = "second",
        .itemNames = &.{ "d.jpg", "e.jpg" },
    };
    var composite = registry.CompositeMediaSource.init(&.{ first.mediaSource(), second.mediaSource() });

    const items = try listAll(arena.allocator(), composite.mediaSource(), 2);

    const expected = [_][]const u8{ "a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg" };
    try std.testing.expectEqual(expected.len, items.len);
    for (expected, 0..) |name, index| {
        try std.testing.expectEqualStrings(name, items[index].displayName);
    }
}

test "composite: an empty child does not end the listing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var empty: ListMediaSource = .{
        .label = "empty",
    };
    var second: ListMediaSource = .{
        .label = "second",
        .itemNames = &.{"a.jpg"},
    };
    var composite = registry.CompositeMediaSource.init(&.{ empty.mediaSource(), second.mediaSource() });

    const items = try listAll(arena.allocator(), composite.mediaSource(), 10);

    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("a.jpg", items[0].displayName);
}

test "a composite of empty children lists nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var one: ListMediaSource = .{
        .label = "one",
    };
    var two: ListMediaSource = .{
        .label = "two",
    };
    var composite = registry.CompositeMediaSource.init(&.{ one.mediaSource(), two.mediaSource() });

    const items = try listAll(arena.allocator(), composite.mediaSource(), 10);

    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "each item says which child it came from" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var first: ListMediaSource = .{
        .label = "first",
        .itemNames = &.{"a.jpg"},
    };
    var second: ListMediaSource = .{
        .label = "second",
        .itemNames = &.{"b.jpg"},
    };
    var composite = registry.CompositeMediaSource.init(&.{ first.mediaSource(), second.mediaSource() });

    const items = try listAll(arena.allocator(), composite.mediaSource(), 10);

    try std.testing.expectEqualStrings("0#first/a.jpg", items[0].sourceId);
    try std.testing.expectEqualStrings("1#second/b.jpg", items[1].sourceId);
}

test "exporting goes to the child the item came from, with the stamp removed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var first: ListMediaSource = .{
        .label = "first",
        .itemNames = &.{"a.jpg"},
    };
    var second: ListMediaSource = .{
        .label = "second",
        .itemNames = &.{"b.jpg"},
    };
    var composite = registry.CompositeMediaSource.init(&.{ first.mediaSource(), second.mediaSource() });
    const source = composite.mediaSource();

    const items = try listAll(arena.allocator(), source, 10);
    _ = try source.openItem(arena.allocator(), std.testing.io, items[1]);

    try std.testing.expectEqual(@as(usize, 0), first.exported.items.len);
    try std.testing.expectEqual(@as(usize, 1), second.exported.items.len);
    try std.testing.expectEqualStrings("second/b.jpg", second.exported.items[0]);
}

test "releasing goes to the child the item came from" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var first: ListMediaSource = .{
        .label = "first",
        .itemNames = &.{"a.jpg"},
    };
    var second: ListMediaSource = .{
        .label = "second",
        .itemNames = &.{"b.jpg"},
    };
    var composite = registry.CompositeMediaSource.init(&.{ first.mediaSource(), second.mediaSource() });
    const source = composite.mediaSource();

    const items = try listAll(arena.allocator(), source, 10);
    try source.closeItem(arena.allocator(), std.testing.io, items[0]);

    try std.testing.expectEqual(@as(usize, 1), first.released.items.len);
    try std.testing.expectEqualStrings("first/a.jpg", first.released.items[0]);
    try std.testing.expectEqual(@as(usize, 0), second.released.items.len);
}

test "each child is asked to delete only its own ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var first: ListMediaSource = .{
        .label = "first",
        .itemNames = &.{"a.jpg"},
    };
    var second: ListMediaSource = .{
        .label = "second",
        .itemNames = &.{"b.jpg"},
    };
    var composite = registry.CompositeMediaSource.init(&.{ first.mediaSource(), second.mediaSource() });
    const source = composite.mediaSource();

    const items = try listAll(arena.allocator(), source, 10);
    try source.deleteItems(arena.allocator(), std.testing.io, &.{ items[0].sourceId, items[1].sourceId });

    try std.testing.expectEqual(@as(usize, 1), first.deleteRequests.items.len);
    try std.testing.expectEqual(@as(usize, 1), first.deleteRequests.items[0].len);
    try std.testing.expectEqualStrings("first/a.jpg", first.deleteRequests.items[0][0]);
    try std.testing.expectEqual(@as(usize, 1), second.deleteRequests.items.len);
    try std.testing.expectEqual(@as(usize, 1), second.deleteRequests.items[0].len);
    try std.testing.expectEqualStrings("second/b.jpg", second.deleteRequests.items[0][0]);
}

test "a child with nothing to delete is not asked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var first: ListMediaSource = .{
        .label = "first",
        .itemNames = &.{"a.jpg"},
    };
    var second: ListMediaSource = .{
        .label = "second",
        .itemNames = &.{"b.jpg"},
    };
    var composite = registry.CompositeMediaSource.init(&.{ first.mediaSource(), second.mediaSource() });
    const source = composite.mediaSource();

    const items = try listAll(arena.allocator(), source, 10);
    try source.deleteItems(arena.allocator(), std.testing.io, &.{items[0].sourceId});

    try std.testing.expectEqual(@as(usize, 1), first.deleteRequests.items.len);
    try std.testing.expectEqualStrings("first/a.jpg", first.deleteRequests.items[0][0]);
    try std.testing.expectEqual(@as(usize, 0), second.deleteRequests.items.len);
}

test "an id that did not come from this composite is refused rather than handed to a child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var first: ListMediaSource = .{
        .label = "first",
        .itemNames = &.{"a.jpg"},
    };
    var composite = registry.CompositeMediaSource.init(&.{first.mediaSource()});

    try std.testing.expectError(error.Thrown, composite.mediaSource().deleteItems(arena.allocator(), std.testing.io, &.{"/somewhere/else.jpg"}));
    try std.testing.expect(std.ascii.indexOfIgnoreCase(errors.lastErrorMessage(), "did not come from this composite") != null);
}

test "an id naming a child that does not exist is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var first: ListMediaSource = .{
        .label = "first",
        .itemNames = &.{"a.jpg"},
    };
    var composite = registry.CompositeMediaSource.init(&.{first.mediaSource()});

    try std.testing.expectError(error.Thrown, composite.mediaSource().deleteItems(arena.allocator(), std.testing.io, &.{"7#first/a.jpg"}));
    try std.testing.expect(std.ascii.indexOfIgnoreCase(errors.lastErrorMessage(), "no child at index 7") != null);
}

test "a malformed cursor is refused rather than silently starting over" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var first: ListMediaSource = .{
        .label = "first",
        .itemNames = &.{"a.jpg"},
    };
    var composite = registry.CompositeMediaSource.init(&.{first.mediaSource()});

    try std.testing.expectError(error.Thrown, composite.mediaSource().listPage(arena.allocator(), std.testing.io, "not-a-cursor", 10));
    try std.testing.expect(std.ascii.indexOfIgnoreCase(errors.lastErrorMessage(), "malformed composite") != null);
}
