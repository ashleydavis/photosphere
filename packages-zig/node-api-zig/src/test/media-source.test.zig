const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const api = @import("api-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const string_lists = @import("string-lists.zig");
const FolderMediaSource = node_api.folder_media_source.FolderMediaSource;
const IMediaItem = node_api.media_source.IMediaItem;
const MediaSourceDeleteError = node_api.media_source.MediaSourceDeleteError;
const IFolderAutoImportSource = api.auto_import_settings.IFolderAutoImportSource;
const RandomUuidGenerator = utils.random_uuid_generator.RandomUuidGenerator;
const path = node_utils.path;

//
// Makes a folder source entry for a path.
//
fn folderSource(folderPath: []const u8, recurse: bool) IFolderAutoImportSource {
    return .{
        .path = folderPath,
        .recurse = recurse,
    };
}

//
// Drains every page of a source into one list, so a test can assert on the whole listing.
//
fn listAll(allocator: std.mem.Allocator, source: *FolderMediaSource, pageSize: usize) ![]IMediaItem {
    var items: std.ArrayList(IMediaItem) = .empty;
    var cursor: ?[]const u8 = null;
    var pages: usize = 0;
    while (true) {
        const page = try source.listPage(allocator, std.testing.io, cursor, pageSize);
        try items.appendSlice(allocator, page.items);
        cursor = page.nextCursor;
        pages += 1;
        if (pages > 100) {
            return error.PagingDidNotTerminate;
        }
        if (cursor == null) {
            break;
        }
    }
    return items.items;
}

//
// The display names of items.
//
fn displayNames(allocator: std.mem.Allocator, items: []const IMediaItem) ![][]const u8 {
    const names = try allocator.alloc([]const u8, items.len);
    for (items, 0..) |item, index| {
        names[index] = item.displayName;
    }
    return names;
}

//
// Checks a list of strings.
//
fn expectStrings(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expectedString, actualString| {
        try std.testing.expectEqualStrings(expectedString, actualString);
    }
}

//
// The state each test starts from (TypeScript: the beforeEach of the describe block).
//
const SourceTest = struct {
    // Holds the test's allocations.
    arena: std.heap.ArenaAllocator,

    // The directory of the test.
    tempDir: []const u8,

    // The watched folder.
    photosDir: []const u8,

    // Where zips are extracted.
    sessionTempDir: []const u8,

    // Names extracted files.
    generator: RandomUuidGenerator,

    //
    // Makes the directories.
    //
    fn init(self: *SourceTest) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const allocator = self.arena.allocator();
        self.tempDir = try temp_dirs.makeTempDir(allocator, std.testing.io, "folder-media-source");
        self.photosDir = try path.join(allocator, &.{ self.tempDir, "photos" });
        self.sessionTempDir = try path.join(allocator, &.{ self.tempDir, "session" });
        try std.Io.Dir.cwd().createDirPath(std.testing.io, self.photosDir);
        try std.Io.Dir.cwd().createDirPath(std.testing.io, self.sessionTempDir);
        self.generator = .{};
    }

    //
    // Removes the directories.
    //
    fn deinit(self: *SourceTest) void {
        temp_dirs.removeTempDir(std.testing.io, self.tempDir);
        self.arena.deinit();
    }

    //
    // Writes a file in the photos folder, creating parent directories as needed.
    //
    fn writePhoto(self: *SourceTest, relativePath: []const u8, contents: []const u8) ![]const u8 {
        const filePath = try path.join(self.arena.allocator(), &.{ self.photosDir, relativePath });
        try test_files.writeFile(std.testing.io, filePath, contents);
        return filePath;
    }

    //
    // Makes a source over the given folders.
    //
    fn source(self: *SourceTest, folders: []const IFolderAutoImportSource) FolderMediaSource {
        return FolderMediaSource.init(self.arena.allocator(), folders, self.sessionTempDir, self.generator.uuidGenerator());
    }
};

test "lists the media files in a folder" {
    var context: SourceTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    _ = try context.writePhoto("a.jpg", "first");
    _ = try context.writePhoto("b.png", "second");

    var source = context.source(&.{folderSource(context.photosDir, true)});
    const page = try source.listPage(allocator, std.testing.io, null, 10);

    try expectStrings(&.{ "a.jpg", "b.png" }, try displayNames(allocator, page.items));
    try std.testing.expect(page.nextCursor == null);
}

test "reports the details of each item" {
    var context: SourceTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    const filePath = try context.writePhoto("a.jpg", "0123456789");

    var source = context.source(&.{folderSource(context.photosDir, true)});
    const page = try source.listPage(allocator, std.testing.io, null, 10);

    try std.testing.expectEqual(@as(usize, 1), page.items.len);
    const item = page.items[0];
    try std.testing.expectEqualStrings(filePath, item.sourceId);
    try std.testing.expectEqualStrings(filePath, item.filePath);
    try std.testing.expectEqualStrings("a.jpg", item.displayName);
    try std.testing.expectEqualStrings("image/jpeg", item.contentType);
    try std.testing.expectEqual(@as(u64, 10), item.size);
    try std.testing.expect(item.createdAt > 0);
}

test "filters out files that are not media" {
    var context: SourceTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    _ = try context.writePhoto("a.jpg", "photo");
    _ = try context.writePhoto("notes.txt", "text");
    _ = try context.writePhoto("drawing.svg", "vector");

    var source = context.source(&.{folderSource(context.photosDir, true)});
    const items = try listAll(allocator, &source, 10);

    try expectStrings(&.{"a.jpg"}, try displayNames(allocator, items));
}

test "pages through a listing" {
    var context: SourceTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;
    for ([_][]const u8{ "a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg" }) |name| {
        _ = try context.writePhoto(name, name);
    }

    var source = context.source(&.{folderSource(context.photosDir, true)});

    const firstPage = try source.listPage(allocator, io, null, 2);
    try expectStrings(&.{ "a.jpg", "b.jpg" }, try displayNames(allocator, firstPage.items));
    try std.testing.expectEqualStrings(try path.join(allocator, &.{ context.photosDir, "b.jpg" }), firstPage.nextCursor.?);

    const secondPage = try source.listPage(allocator, io, firstPage.nextCursor, 2);
    try expectStrings(&.{ "c.jpg", "d.jpg" }, try displayNames(allocator, secondPage.items));

    const thirdPage = try source.listPage(allocator, io, secondPage.nextCursor, 2);
    try expectStrings(&.{"e.jpg"}, try displayNames(allocator, thirdPage.items));
    try std.testing.expect(thirdPage.nextCursor == null);
}

test "every item is listed exactly once across pages" {
    var context: SourceTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    const names = [_][]const u8{ "a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg", "f.jpg", "g.jpg" };
    for (names) |name| {
        _ = try context.writePhoto(name, name);
    }

    var source = context.source(&.{folderSource(context.photosDir, true)});
    const items = try listAll(allocator, &source, 3);

    try expectStrings(&names, try displayNames(allocator, items));
}

test "resumes after a cursor whose item has been deleted, without going back to the start" {
    var context: SourceTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;
    for ([_][]const u8{ "a.jpg", "b.jpg", "c.jpg", "d.jpg" }) |name| {
        _ = try context.writePhoto(name, name);
    }

    var source = context.source(&.{folderSource(context.photosDir, true)});
    const firstPage = try source.listPage(allocator, io, null, 2);
    try expectStrings(&.{ "a.jpg", "b.jpg" }, try displayNames(allocator, firstPage.items));

    // The item the cursor names is gone by the time the next page is asked for, which is the
    // ordinary case when cleanup deletes source files as they are imported. A fresh source
    // stands in for the task being restarted and resuming from the persisted cursor, so there
    // is no cached listing to find the missing item in.
    try std.Io.Dir.cwd().deleteFile(io, try path.join(allocator, &.{ context.photosDir, "b.jpg" }));

    var resumedSource = context.source(&.{folderSource(context.photosDir, true)});
    const nextPage = try resumedSource.listPage(allocator, io, try path.join(allocator, &.{ context.photosDir, "b.jpg" }), 10);
    try expectStrings(&.{ "c.jpg", "d.jpg" }, try displayNames(allocator, nextPage.items));
}

test "a cursor past the end of the listing yields nothing" {
    var context: SourceTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    _ = try context.writePhoto("a.jpg", "one");

    var source = context.source(&.{folderSource(context.photosDir, true)});
    const page = try source.listPage(allocator, std.testing.io, try path.join(allocator, &.{ context.photosDir, "zz.jpg" }), 10);

    try std.testing.expectEqual(@as(usize, 0), page.items.len);
    try std.testing.expect(page.nextCursor == null);
}

test "a recursive folder includes files in subfolders" {
    var context: SourceTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    _ = try context.writePhoto("a.jpg", "top");
    _ = try context.writePhoto("holiday/b.jpg", "nested");

    var source = context.source(&.{folderSource(context.photosDir, true)});
    const names = try displayNames(allocator, try listAll(allocator, &source, 10));
    string_lists.sortStrings(names);

    try expectStrings(&.{ "a.jpg", "b.jpg" }, names);
}

test "a non-recursive folder takes only the files directly in it" {
    var context: SourceTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    _ = try context.writePhoto("a.jpg", "top");
    _ = try context.writePhoto("holiday/b.jpg", "nested");

    var source = context.source(&.{folderSource(context.photosDir, false)});
    const items = try listAll(allocator, &source, 10);

    try expectStrings(&.{"a.jpg"}, try displayNames(allocator, items));
}

test "lists across several folders" {
    var context: SourceTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    const otherDir = try path.join(allocator, &.{ context.tempDir, "more-photos" });
    _ = try context.writePhoto("a.jpg", "one");
    try test_files.writeFile(std.testing.io, try path.join(allocator, &.{ otherDir, "b.jpg" }), "two");

    var source = context.source(&.{
        folderSource(context.photosDir, true),
        folderSource(otherDir, true),
    });
    const names = try displayNames(allocator, try listAll(allocator, &source, 10));
    string_lists.sortStrings(names);

    try expectStrings(&.{ "a.jpg", "b.jpg" }, names);
}

test "a folder that does not exist yields nothing rather than throwing" {
    var context: SourceTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    var source = context.source(&.{folderSource(try path.join(allocator, &.{ context.tempDir, "absent" }), true)});
    const page = try source.listPage(allocator, std.testing.io, null, 10);

    try std.testing.expectEqual(@as(usize, 0), page.items.len);
    try std.testing.expect(page.nextCursor == null);
}

test "openItem returns the file path unchanged and closeItem does nothing" {
    var context: SourceTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;
    const filePath = try context.writePhoto("a.jpg", "photo");

    var source = context.source(&.{folderSource(context.photosDir, true)});
    const page = try source.listPage(allocator, io, null, 10);

    try std.testing.expectEqualStrings(filePath, try source.openItem(allocator, io, page.items[0]));
    try source.closeItem(allocator, io, page.items[0]);
    try std.testing.expect(test_files.fileExists(io, filePath));
}

test "a file added later shows up in the next listing, which is how each run finds new photos" {
    var context: SourceTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    _ = try context.writePhoto("a.jpg", "photo");

    var source = context.source(&.{folderSource(context.photosDir, true)});
    try std.testing.expectEqual(@as(usize, 1), (try source.listPage(allocator, std.testing.io, null, 10)).items.len);

    _ = try context.writePhoto("b.jpg", "another");

    // A fresh source, because a run that has ended takes its source with it: this is what the
    // next run does, and it is the only thing that finds a photo that arrived in between.
    var nextRun = context.source(&.{folderSource(context.photosDir, true)});
    const items = try listAll(allocator, &nextRun, 10);

    try expectStrings(&.{ "a.jpg", "b.jpg" }, try displayNames(allocator, items));
}

test "deleteItems removes the source files" {
    var context: SourceTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;
    const firstPath = try context.writePhoto("a.jpg", "one");
    const secondPath = try context.writePhoto("b.jpg", "two");

    var source = context.source(&.{folderSource(context.photosDir, true)});
    const items = try listAll(allocator, &source, 10);

    try source.deleteItems(allocator, io, &.{items[0].sourceId});

    try std.testing.expect(!test_files.fileExists(io, firstPath));
    try std.testing.expect(test_files.fileExists(io, secondPath));
}

test "deleting an item that is already gone is not an error" {
    var context: SourceTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;
    const filePath = try context.writePhoto("a.jpg", "one");

    var source = context.source(&.{folderSource(context.photosDir, true)});
    const items = try listAll(allocator, &source, 10);
    try std.Io.Dir.cwd().deleteFile(io, filePath);

    try source.deleteItems(allocator, io, &.{items[0].sourceId});
}

test "deleting an item the source has never listed names it in the error" {
    var context: SourceTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;
    _ = try context.writePhoto("a.jpg", "one");

    var source = context.source(&.{folderSource(context.photosDir, true)});
    _ = try listAll(allocator, &source, 10);

    const result = source.deleteItems(allocator, io, &.{"/somewhere/else.jpg"});
    try std.testing.expectError(error.Thrown, result);
    try std.testing.expect(MediaSourceDeleteError.isInstance(error.Thrown));
    try expectStrings(&.{"/somewhere/else.jpg"}, MediaSourceDeleteError.sourceIds());
}
