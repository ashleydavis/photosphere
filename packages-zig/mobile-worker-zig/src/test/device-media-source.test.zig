//
// Tests for device-media-source.zig: the device photo library as a media source, over a native caller that replies to the media library requests.
//

const std = @import("std");
const utils = @import("utils-zig");
const api = @import("api-zig");
const mobile_worker = @import("mobile-worker-zig");

const DeviceMediaSource = mobile_worker.device_media_source.DeviceMediaSource;
const INativeCaller = utils.native_caller.INativeCaller;
const IAutoImportSource = api.auto_import_settings.IAutoImportSource;
const MediaSourceDeleteError = api.media_source.MediaSourceDeleteError;
const errors = utils.errors;

//
// A native caller that replies to each media library request with a canned reply and records the request it was given.
//
const CannedNativeCaller = struct {
    // The reply to mediaLibraryList.
    list_reply: []const u8,

    // The reply to mediaLibraryOpen.
    open_reply: []const u8,

    // The reply to mediaLibraryDelete.
    delete_reply: []const u8,

    // The method of the last request.
    last_method: []const u8,

    // The JSON text of the last request.
    last_request: []const u8,

    // Where the record of the requests is kept.
    allocator: std.mem.Allocator,

    //
    // The native caller for this canned native caller.
    //
    fn nativeCaller(self: *CannedNativeCaller) INativeCaller {
        return .{
            .ptr = self,
            .request = request,
        };
    }

    //
    // Replies to a request with the canned reply for its method and records it.
    //
    fn request(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, method: []const u8, request_json: []const u8) anyerror![]const u8 {
        _ = io;
        const self: *CannedNativeCaller = @ptrCast(@alignCast(ptr));
        self.last_method = try self.allocator.dupe(u8, method);
        self.last_request = try self.allocator.dupe(u8, request_json);
        if (std.mem.eql(u8, method, "mediaLibraryList")) {
            return try allocator.dupe(u8, self.list_reply);
        }
        if (std.mem.eql(u8, method, "mediaLibraryOpen")) {
            return try allocator.dupe(u8, self.open_reply);
        }
        if (std.mem.eql(u8, method, "mediaLibraryClose")) {
            return try allocator.dupe(u8, "null");
        }
        if (std.mem.eql(u8, method, "mediaLibraryDelete")) {
            return try allocator.dupe(u8, self.delete_reply);
        }
        return errors.throwError("unexpected method {s}", .{method});
    }
};

//
// A library page with one item in each of two albums.
//
const TWO_ALBUM_PAGE =
    \\{"items":[
    \\{"id":"1","displayName":"a.jpg","mimeType":"image/jpeg","size":10,"createdAtMs":1000,"albumId":"cam"},
    \\{"id":"2","displayName":"b.jpg","mimeType":"image/jpeg","size":20,"createdAtMs":2000,"albumId":"other"}
    \\],"nextCursor":"2"}
;

//
// A native caller with a canned reply for every request.
//
fn newNativeCaller(allocator: std.mem.Allocator) CannedNativeCaller {
    return .{
        .list_reply = TWO_ALBUM_PAGE,
        .open_reply = "\"/cache/.media-tmp/1.jpg\"",
        .delete_reply = "{\"deletedIds\":[\"1\"],\"failedIds\":[]}",
        .last_method = "",
        .last_request = "",
        .allocator = allocator,
    };
}

//
// A device album source for the album.
//
fn albumSource(album_id: []const u8) IAutoImportSource {
    return .{
        .@"device-album" = .{
            .albumId = album_id,
        },
    };
}

test "DeviceMediaSource: an empty album list covers the whole library" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var native_caller = newNativeCaller(arena.allocator());
    var source = try DeviceMediaSource.init(arena.allocator(), &.{}, native_caller.nativeCaller());
    const page = try source.listPage(arena.allocator(), std.testing.io, null, 50);
    try std.testing.expectEqual(@as(usize, 2), page.items.len);
    try std.testing.expectEqualStrings("{\"cursor\":\"\",\"pageSize\":50}", native_caller.last_request);
    try std.testing.expectEqualStrings("mediaLibraryList", native_caller.last_method);
}

test "DeviceMediaSource: the reserved all album covers the whole library" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var native_caller = newNativeCaller(arena.allocator());
    var source = try DeviceMediaSource.init(arena.allocator(), &.{ albumSource("cam"), albumSource("all") }, native_caller.nativeCaller());
    const page = try source.listPage(arena.allocator(), std.testing.io, null, 50);
    try std.testing.expectEqual(@as(usize, 2), page.items.len);
}

test "DeviceMediaSource: named albums keep only their items and the page still yields its cursor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var native_caller = newNativeCaller(arena.allocator());
    var source = try DeviceMediaSource.init(arena.allocator(), &.{albumSource("nothing-here")}, native_caller.nativeCaller());
    const page = try source.listPage(arena.allocator(), std.testing.io, "2", 50);
    try std.testing.expectEqual(@as(usize, 0), page.items.len);
    try std.testing.expectEqualStrings("2", page.nextCursor.?);
    try std.testing.expectEqualStrings("{\"cursor\":\"2\",\"pageSize\":50}", native_caller.last_request);

    var camera_source = try DeviceMediaSource.init(arena.allocator(), &.{albumSource("cam")}, native_caller.nativeCaller());
    const camera_page = try camera_source.listPage(arena.allocator(), std.testing.io, null, 50);
    try std.testing.expectEqual(@as(usize, 1), camera_page.items.len);
    try std.testing.expectEqualStrings("1", camera_page.items[0].sourceId);
    try std.testing.expectEqualStrings("a.jpg", camera_page.items[0].displayName);
    try std.testing.expectEqualStrings("image/jpeg", camera_page.items[0].contentType);
    try std.testing.expectEqual(@as(u64, 10), camera_page.items[0].size);
    try std.testing.expectEqual(@as(i64, 1000), camera_page.items[0].createdAt);
    try std.testing.expectEqualStrings("", camera_page.items[0].filePath);
}

test "DeviceMediaSource: the last page has no cursor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var native_caller = newNativeCaller(arena.allocator());
    native_caller.list_reply = "{\"items\":[]}";
    var source = try DeviceMediaSource.init(arena.allocator(), &.{}, native_caller.nativeCaller());
    const page = try source.listPage(arena.allocator(), std.testing.io, "9", 50);
    try std.testing.expect(page.nextCursor == null);
}

test "DeviceMediaSource: an unreadable list answer is an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var native_caller = newNativeCaller(arena.allocator());
    native_caller.list_reply = "not json";
    var source = try DeviceMediaSource.init(arena.allocator(), &.{}, native_caller.nativeCaller());
    try std.testing.expectError(error.Thrown, source.listPage(arena.allocator(), std.testing.io, null, 50));
    try std.testing.expect(std.mem.indexOf(u8, errors.lastErrorMessage(), "mediaLibraryList") != null);
}

test "DeviceMediaSource: openItem returns the path the shell copied the item to" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var native_caller = newNativeCaller(arena.allocator());
    var source = try DeviceMediaSource.init(arena.allocator(), &.{}, native_caller.nativeCaller());
    const page = try source.listPage(arena.allocator(), std.testing.io, null, 50);
    const path = try source.openItem(arena.allocator(), std.testing.io, page.items[0]);
    try std.testing.expectEqualStrings("/cache/.media-tmp/1.jpg", path);
    try std.testing.expectEqualStrings("{\"itemId\":\"1\"}", native_caller.last_request);
}

test "DeviceMediaSource: closeItem asks the shell to remove the copy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var native_caller = newNativeCaller(arena.allocator());
    var source = try DeviceMediaSource.init(arena.allocator(), &.{}, native_caller.nativeCaller());
    const page = try source.listPage(arena.allocator(), std.testing.io, null, 50);
    try source.closeItem(arena.allocator(), std.testing.io, page.items[1]);
    try std.testing.expectEqualStrings("mediaLibraryClose", native_caller.last_method);
    try std.testing.expectEqualStrings("{\"itemId\":\"2\"}", native_caller.last_request);
}

test "DeviceMediaSource: deleteItems succeeds when the shell deleted everything" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var native_caller = newNativeCaller(arena.allocator());
    var source = try DeviceMediaSource.init(arena.allocator(), &.{}, native_caller.nativeCaller());
    try source.deleteItems(arena.allocator(), std.testing.io, &.{"1"});
    try std.testing.expectEqualStrings("{\"itemIds\":[\"1\"]}", native_caller.last_request);
}

test "DeviceMediaSource: deleteItems names the items the shell did not delete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var native_caller = newNativeCaller(arena.allocator());
    native_caller.delete_reply = "{\"deletedIds\":[\"1\"],\"failedIds\":[\"2\",\"3\"]}";
    var source = try DeviceMediaSource.init(arena.allocator(), &.{}, native_caller.nativeCaller());
    const result = source.deleteItems(arena.allocator(), std.testing.io, &.{ "1", "2", "3" });
    try std.testing.expectError(error.Thrown, result);
    try std.testing.expect(MediaSourceDeleteError.isInstance(error.Thrown));
    try std.testing.expectEqual(@as(usize, 2), MediaSourceDeleteError.sourceIds().len);
    try std.testing.expectEqualStrings("2", MediaSourceDeleteError.sourceIds()[0]);
    try std.testing.expectEqualStrings("3", MediaSourceDeleteError.sourceIds()[1]);
}

test "buildDeviceMediaSource: without a host requester it is an error naming the phone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator: utils.test_uuid_generator.TestUuidGenerator = .{};
    try std.testing.expectError(error.Thrown, mobile_worker.device_media_source.buildDeviceMediaSource(arena.allocator(), &.{albumSource("all")}, .{
        .sessionTempDir = "/tmp/session",
        .uuidGenerator = generator.uuidGenerator(),
        .nativeCaller = null,
    }));
    try std.testing.expect(std.mem.indexOf(u8, errors.lastErrorMessage(), "on a phone") != null);
}

test "maps a library page into media items" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var native_caller = newNativeCaller(arena.allocator());
    native_caller.list_reply = "{\"items\":[{\"id\":\"one\",\"displayName\":\"one.jpg\",\"mimeType\":\"image/jpeg\",\"size\":1024,\"createdAtMs\":1700000000000,\"albumId\":\"camera\"}],\"nextCursor\":\"10\"}";
    var source = try DeviceMediaSource.init(arena.allocator(), &.{albumSource("all")}, native_caller.nativeCaller());

    const page = try source.listPage(arena.allocator(), std.testing.io, null, 50);

    try std.testing.expectEqualStrings("10", page.nextCursor.?);
    try std.testing.expectEqual(@as(usize, 1), page.items.len);
    try std.testing.expectEqualStrings("one", page.items[0].sourceId);
    try std.testing.expectEqualStrings("one.jpg", page.items[0].displayName);
    try std.testing.expectEqualStrings("image/jpeg", page.items[0].contentType);
    try std.testing.expectEqual(@as(u64, 1024), page.items[0].size);
    try std.testing.expectEqual(@as(i64, 1700000000000), page.items[0].createdAt);

    // The path is only known after the item is opened, so there is nothing to read yet.
    try std.testing.expectEqualStrings("", page.items[0].filePath);
}

test "the reserved everything album takes the whole library rather than filtering by it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var native_caller = newNativeCaller(arena.allocator());
    native_caller.list_reply = "{\"items\":[{\"id\":\"one\",\"displayName\":\"one.jpg\",\"mimeType\":\"image/jpeg\",\"size\":1024,\"createdAtMs\":1,\"albumId\":\"camera\"},{\"id\":\"two\",\"displayName\":\"two.jpg\",\"mimeType\":\"image/jpeg\",\"size\":1024,\"createdAtMs\":1,\"albumId\":\"screenshots\"}]}";
    var source = try DeviceMediaSource.init(arena.allocator(), &.{albumSource("all")}, native_caller.nativeCaller());

    const page = try source.listPage(arena.allocator(), std.testing.io, null, 50);

    try std.testing.expectEqual(@as(usize, 2), page.items.len);
    try std.testing.expectEqualStrings("one", page.items[0].sourceId);
    try std.testing.expectEqualStrings("two", page.items[1].sourceId);
}

test "keeps only the items in the named albums" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var native_caller = newNativeCaller(arena.allocator());
    native_caller.list_reply = "{\"items\":[{\"id\":\"one\",\"displayName\":\"one.jpg\",\"mimeType\":\"image/jpeg\",\"size\":1024,\"createdAtMs\":1,\"albumId\":\"camera\"},{\"id\":\"two\",\"displayName\":\"two.jpg\",\"mimeType\":\"image/jpeg\",\"size\":1024,\"createdAtMs\":1,\"albumId\":\"screenshots\"},{\"id\":\"three\",\"displayName\":\"three.jpg\",\"mimeType\":\"image/jpeg\",\"size\":1024,\"createdAtMs\":1,\"albumId\":\"camera\"}]}";
    var source = try DeviceMediaSource.init(arena.allocator(), &.{albumSource("camera")}, native_caller.nativeCaller());

    const page = try source.listPage(arena.allocator(), std.testing.io, null, 50);

    try std.testing.expectEqual(@as(usize, 2), page.items.len);
    try std.testing.expectEqualStrings("one", page.items[0].sourceId);
    try std.testing.expectEqualStrings("three", page.items[1].sourceId);
}

test "a page the album filter empties still yields its cursor so the walk carries on" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var native_caller = newNativeCaller(arena.allocator());
    native_caller.list_reply = "{\"items\":[{\"id\":\"one\",\"displayName\":\"one.jpg\",\"mimeType\":\"image/jpeg\",\"size\":1024,\"createdAtMs\":1,\"albumId\":\"screenshots\"}],\"nextCursor\":\"10\"}";
    var source = try DeviceMediaSource.init(arena.allocator(), &.{albumSource("camera")}, native_caller.nativeCaller());

    const page = try source.listPage(arena.allocator(), std.testing.io, null, 50);

    try std.testing.expectEqual(@as(usize, 0), page.items.len);
    try std.testing.expectEqualStrings("10", page.nextCursor.?);
}

test "a missing cursor crosses the bridge as an empty string, which starts at the beginning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var native_caller = newNativeCaller(arena.allocator());
    native_caller.list_reply = "{\"items\":[]}";
    var source = try DeviceMediaSource.init(arena.allocator(), &.{albumSource("all")}, native_caller.nativeCaller());

    _ = try source.listPage(arena.allocator(), std.testing.io, null, 50);

    try std.testing.expectEqualStrings("{\"cursor\":\"\",\"pageSize\":50}", native_caller.last_request);
}

test "a cursor is passed through unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var native_caller = newNativeCaller(arena.allocator());
    native_caller.list_reply = "{\"items\":[]}";
    var source = try DeviceMediaSource.init(arena.allocator(), &.{albumSource("all")}, native_caller.nativeCaller());

    _ = try source.listPage(arena.allocator(), std.testing.io, "42", 50);

    try std.testing.expectEqualStrings("{\"cursor\":\"42\",\"pageSize\":50}", native_caller.last_request);
}

test "opens and closes through the library" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var native_caller = newNativeCaller(arena.allocator());
    native_caller.open_reply = "\".media-tmp/one.jpg\"";
    var source = try DeviceMediaSource.init(arena.allocator(), &.{albumSource("all")}, native_caller.nativeCaller());
    const item: api.media_source.IMediaItem = .{
        .sourceId = "one",
        .filePath = "",
        .displayName = "one.jpg",
        .contentType = "image/jpeg",
        .size = 1024,
        .createdAt = 1700000000000,
    };

    const openedPath = try source.openItem(arena.allocator(), std.testing.io, item);

    try std.testing.expectEqualStrings(".media-tmp/one.jpg", openedPath);
    try std.testing.expectEqualStrings("mediaLibraryOpen", native_caller.last_method);
    try std.testing.expectEqualStrings("{\"itemId\":\"one\"}", native_caller.last_request);

    try source.closeItem(arena.allocator(), std.testing.io, item);

    try std.testing.expectEqualStrings("mediaLibraryClose", native_caller.last_method);
    try std.testing.expectEqualStrings("{\"itemId\":\"one\"}", native_caller.last_request);
}

test "a delete the library completed reports no failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var native_caller = newNativeCaller(arena.allocator());
    native_caller.delete_reply = "{\"deletedIds\":[\"one\",\"two\"],\"failedIds\":[]}";
    var source = try DeviceMediaSource.init(arena.allocator(), &.{albumSource("all")}, native_caller.nativeCaller());

    try source.deleteItems(arena.allocator(), std.testing.io, &.{ "one", "two" });

    try std.testing.expectEqualStrings("mediaLibraryDelete", native_caller.last_method);
    try std.testing.expectEqualStrings("{\"itemIds\":[\"one\",\"two\"]}", native_caller.last_request);
}

test "a delete the library refused names the items that are still on the device" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var native_caller = newNativeCaller(arena.allocator());
    native_caller.delete_reply = "{\"deletedIds\":[\"one\"],\"failedIds\":[\"two\"]}";
    var source = try DeviceMediaSource.init(arena.allocator(), &.{albumSource("all")}, native_caller.nativeCaller());

    try std.testing.expectError(error.Thrown, source.deleteItems(arena.allocator(), std.testing.io, &.{ "one", "two" }));

    try std.testing.expect(MediaSourceDeleteError.isInstance(error.Thrown));
    try std.testing.expectEqual(@as(usize, 1), MediaSourceDeleteError.sourceIds().len);
    try std.testing.expectEqualStrings("two", MediaSourceDeleteError.sourceIds()[0]);
}

// The import task reaches the library only through IMediaSource, so the source the builder makes is driven through it here.
test "buildDeviceMediaSource: the source it builds lists, opens, closes and deletes through the media source interface" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var native_caller = newNativeCaller(allocator);
    var generator: utils.test_uuid_generator.TestUuidGenerator = .{};
    const source = try mobile_worker.device_media_source.buildDeviceMediaSource(allocator, &.{albumSource("cam")}, .{
        .sessionTempDir = "/tmp/session",
        .uuidGenerator = generator.uuidGenerator(),
        .nativeCaller = native_caller.nativeCaller(),
    });

    const page = try source.listPage(allocator, std.testing.io, null, 50);
    try std.testing.expectEqual(@as(usize, 1), page.items.len);
    try std.testing.expectEqualStrings("1", page.items[0].sourceId);
    try std.testing.expectEqualStrings("mediaLibraryList", native_caller.last_method);

    try std.testing.expectEqualStrings("/cache/.media-tmp/1.jpg", try source.openItem(allocator, std.testing.io, page.items[0]));
    try std.testing.expectEqualStrings("mediaLibraryOpen", native_caller.last_method);

    try source.closeItem(allocator, std.testing.io, page.items[0]);
    try std.testing.expectEqualStrings("mediaLibraryClose", native_caller.last_method);

    try source.deleteItems(allocator, std.testing.io, &.{"1"});
    try std.testing.expectEqualStrings("mediaLibraryDelete", native_caller.last_method);
    try std.testing.expectEqualStrings("{\"itemIds\":[\"1\"]}", native_caller.last_request);
}

test "DeviceMediaSource: an unreadable open answer is an error naming the request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var native_caller = newNativeCaller(arena.allocator());
    native_caller.open_reply = "not json";
    var source = try DeviceMediaSource.init(arena.allocator(), &.{}, native_caller.nativeCaller());
    const page = try source.listPage(arena.allocator(), std.testing.io, null, 50);
    try std.testing.expectError(error.Thrown, source.openItem(arena.allocator(), std.testing.io, page.items[0]));
    try std.testing.expect(std.mem.indexOf(u8, errors.lastErrorMessage(), "mediaLibraryOpen") != null);
}

test "DeviceMediaSource: an unreadable delete answer is an error naming the request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var native_caller = newNativeCaller(arena.allocator());
    native_caller.delete_reply = "not json";
    var source = try DeviceMediaSource.init(arena.allocator(), &.{}, native_caller.nativeCaller());
    try std.testing.expectError(error.Thrown, source.deleteItems(arena.allocator(), std.testing.io, &.{"1"}));
    try std.testing.expect(std.mem.indexOf(u8, errors.lastErrorMessage(), "mediaLibraryDelete") != null);
}
