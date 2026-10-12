//
// Tests for device-media-source.zig: the device photo library as a media source, over a host that answers the media library requests.
//

const std = @import("std");
const utils = @import("utils-zig");
const api = @import("api-zig");
const mobile_worker = @import("mobile-worker-zig");

const DeviceMediaSource = mobile_worker.device_media_source.DeviceMediaSource;
const IHostRequester = utils.host_requester.IHostRequester;
const IAutoImportSource = api.auto_import_settings.IAutoImportSource;
const MediaSourceDeleteError = api.media_source.MediaSourceDeleteError;
const errors = utils.errors;

//
// A host that answers each media library request with a canned reply and records the request it was given.
//
const CannedHost = struct {
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
    // The host requester for this canned host.
    //
    fn requester(self: *CannedHost) IHostRequester {
        return .{
            .ptr = self,
            .request = request,
        };
    }

    //
    // Answers a request with the canned reply for its method and records it.
    //
    fn request(ptr: *anyopaque, allocator: std.mem.Allocator, method: []const u8, request_json: []const u8) anyerror![]const u8 {
        const self: *CannedHost = @ptrCast(@alignCast(ptr));
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
// A host with a canned reply for every request.
//
fn newHost(allocator: std.mem.Allocator) CannedHost {
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
    var host = newHost(arena.allocator());
    var source = try DeviceMediaSource.init(arena.allocator(), &.{}, host.requester());
    const page = try source.listPage(arena.allocator(), null, 50);
    try std.testing.expectEqual(@as(usize, 2), page.items.len);
    try std.testing.expectEqualStrings("{\"cursor\":\"\",\"pageSize\":50}", host.last_request);
    try std.testing.expectEqualStrings("mediaLibraryList", host.last_method);
}

test "DeviceMediaSource: the reserved all album covers the whole library" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = newHost(arena.allocator());
    var source = try DeviceMediaSource.init(arena.allocator(), &.{ albumSource("cam"), albumSource("all") }, host.requester());
    const page = try source.listPage(arena.allocator(), null, 50);
    try std.testing.expectEqual(@as(usize, 2), page.items.len);
}

test "DeviceMediaSource: named albums keep only their items and the page still yields its cursor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = newHost(arena.allocator());
    var source = try DeviceMediaSource.init(arena.allocator(), &.{albumSource("nothing-here")}, host.requester());
    const page = try source.listPage(arena.allocator(), "2", 50);
    try std.testing.expectEqual(@as(usize, 0), page.items.len);
    try std.testing.expectEqualStrings("2", page.nextCursor.?);
    try std.testing.expectEqualStrings("{\"cursor\":\"2\",\"pageSize\":50}", host.last_request);

    var camera_source = try DeviceMediaSource.init(arena.allocator(), &.{albumSource("cam")}, host.requester());
    const camera_page = try camera_source.listPage(arena.allocator(), null, 50);
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
    var host = newHost(arena.allocator());
    host.list_reply = "{\"items\":[]}";
    var source = try DeviceMediaSource.init(arena.allocator(), &.{}, host.requester());
    const page = try source.listPage(arena.allocator(), "9", 50);
    try std.testing.expect(page.nextCursor == null);
}

test "DeviceMediaSource: an unreadable list answer is an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = newHost(arena.allocator());
    host.list_reply = "not json";
    var source = try DeviceMediaSource.init(arena.allocator(), &.{}, host.requester());
    try std.testing.expectError(error.Thrown, source.listPage(arena.allocator(), null, 50));
    try std.testing.expect(std.mem.indexOf(u8, errors.lastErrorMessage(), "mediaLibraryList") != null);
}

test "DeviceMediaSource: openItem returns the path the shell copied the item to" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = newHost(arena.allocator());
    var source = try DeviceMediaSource.init(arena.allocator(), &.{}, host.requester());
    const page = try source.listPage(arena.allocator(), null, 50);
    const path = try source.openItem(arena.allocator(), page.items[0]);
    try std.testing.expectEqualStrings("/cache/.media-tmp/1.jpg", path);
    try std.testing.expectEqualStrings("{\"itemId\":\"1\"}", host.last_request);
}

test "DeviceMediaSource: closeItem asks the shell to remove the copy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = newHost(arena.allocator());
    var source = try DeviceMediaSource.init(arena.allocator(), &.{}, host.requester());
    const page = try source.listPage(arena.allocator(), null, 50);
    try source.closeItem(arena.allocator(), page.items[1]);
    try std.testing.expectEqualStrings("mediaLibraryClose", host.last_method);
    try std.testing.expectEqualStrings("{\"itemId\":\"2\"}", host.last_request);
}

test "DeviceMediaSource: deleteItems succeeds when the shell deleted everything" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = newHost(arena.allocator());
    var source = try DeviceMediaSource.init(arena.allocator(), &.{}, host.requester());
    try source.deleteItems(arena.allocator(), &.{"1"});
    try std.testing.expectEqualStrings("{\"itemIds\":[\"1\"]}", host.last_request);
}

test "DeviceMediaSource: deleteItems names the items the shell did not delete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = newHost(arena.allocator());
    host.delete_reply = "{\"deletedIds\":[\"1\"],\"failedIds\":[\"2\",\"3\"]}";
    var source = try DeviceMediaSource.init(arena.allocator(), &.{}, host.requester());
    const result = source.deleteItems(arena.allocator(), &.{ "1", "2", "3" });
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
        .hostRequester = null,
    }));
    try std.testing.expect(std.mem.indexOf(u8, errors.lastErrorMessage(), "on a phone") != null);
}

test "maps a library page into media items" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = newHost(arena.allocator());
    host.list_reply = "{\"items\":[{\"id\":\"one\",\"displayName\":\"one.jpg\",\"mimeType\":\"image/jpeg\",\"size\":1024,\"createdAtMs\":1700000000000,\"albumId\":\"camera\"}],\"nextCursor\":\"10\"}";
    var source = try DeviceMediaSource.init(arena.allocator(), &.{albumSource("all")}, host.requester());

    const page = try source.listPage(arena.allocator(), null, 50);

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
    var host = newHost(arena.allocator());
    host.list_reply = "{\"items\":[{\"id\":\"one\",\"displayName\":\"one.jpg\",\"mimeType\":\"image/jpeg\",\"size\":1024,\"createdAtMs\":1,\"albumId\":\"camera\"},{\"id\":\"two\",\"displayName\":\"two.jpg\",\"mimeType\":\"image/jpeg\",\"size\":1024,\"createdAtMs\":1,\"albumId\":\"screenshots\"}]}";
    var source = try DeviceMediaSource.init(arena.allocator(), &.{albumSource("all")}, host.requester());

    const page = try source.listPage(arena.allocator(), null, 50);

    try std.testing.expectEqual(@as(usize, 2), page.items.len);
    try std.testing.expectEqualStrings("one", page.items[0].sourceId);
    try std.testing.expectEqualStrings("two", page.items[1].sourceId);
}

test "keeps only the items in the named albums" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = newHost(arena.allocator());
    host.list_reply = "{\"items\":[{\"id\":\"one\",\"displayName\":\"one.jpg\",\"mimeType\":\"image/jpeg\",\"size\":1024,\"createdAtMs\":1,\"albumId\":\"camera\"},{\"id\":\"two\",\"displayName\":\"two.jpg\",\"mimeType\":\"image/jpeg\",\"size\":1024,\"createdAtMs\":1,\"albumId\":\"screenshots\"},{\"id\":\"three\",\"displayName\":\"three.jpg\",\"mimeType\":\"image/jpeg\",\"size\":1024,\"createdAtMs\":1,\"albumId\":\"camera\"}]}";
    var source = try DeviceMediaSource.init(arena.allocator(), &.{albumSource("camera")}, host.requester());

    const page = try source.listPage(arena.allocator(), null, 50);

    try std.testing.expectEqual(@as(usize, 2), page.items.len);
    try std.testing.expectEqualStrings("one", page.items[0].sourceId);
    try std.testing.expectEqualStrings("three", page.items[1].sourceId);
}

test "a page the album filter empties still yields its cursor so the walk carries on" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = newHost(arena.allocator());
    host.list_reply = "{\"items\":[{\"id\":\"one\",\"displayName\":\"one.jpg\",\"mimeType\":\"image/jpeg\",\"size\":1024,\"createdAtMs\":1,\"albumId\":\"screenshots\"}],\"nextCursor\":\"10\"}";
    var source = try DeviceMediaSource.init(arena.allocator(), &.{albumSource("camera")}, host.requester());

    const page = try source.listPage(arena.allocator(), null, 50);

    try std.testing.expectEqual(@as(usize, 0), page.items.len);
    try std.testing.expectEqualStrings("10", page.nextCursor.?);
}

test "a missing cursor crosses the bridge as an empty string, which starts at the beginning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = newHost(arena.allocator());
    host.list_reply = "{\"items\":[]}";
    var source = try DeviceMediaSource.init(arena.allocator(), &.{albumSource("all")}, host.requester());

    _ = try source.listPage(arena.allocator(), null, 50);

    try std.testing.expectEqualStrings("{\"cursor\":\"\",\"pageSize\":50}", host.last_request);
}

test "a cursor is passed through unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = newHost(arena.allocator());
    host.list_reply = "{\"items\":[]}";
    var source = try DeviceMediaSource.init(arena.allocator(), &.{albumSource("all")}, host.requester());

    _ = try source.listPage(arena.allocator(), "42", 50);

    try std.testing.expectEqualStrings("{\"cursor\":\"42\",\"pageSize\":50}", host.last_request);
}

test "opens and closes through the library" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = newHost(arena.allocator());
    host.open_reply = "\".media-tmp/one.jpg\"";
    var source = try DeviceMediaSource.init(arena.allocator(), &.{albumSource("all")}, host.requester());
    const item: api.media_source.IMediaItem = .{
        .sourceId = "one",
        .filePath = "",
        .displayName = "one.jpg",
        .contentType = "image/jpeg",
        .size = 1024,
        .createdAt = 1700000000000,
    };

    const openedPath = try source.openItem(arena.allocator(), item);

    try std.testing.expectEqualStrings(".media-tmp/one.jpg", openedPath);
    try std.testing.expectEqualStrings("mediaLibraryOpen", host.last_method);
    try std.testing.expectEqualStrings("{\"itemId\":\"one\"}", host.last_request);

    try source.closeItem(arena.allocator(), item);

    try std.testing.expectEqualStrings("mediaLibraryClose", host.last_method);
    try std.testing.expectEqualStrings("{\"itemId\":\"one\"}", host.last_request);
}

test "a delete the library completed reports no failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = newHost(arena.allocator());
    host.delete_reply = "{\"deletedIds\":[\"one\",\"two\"],\"failedIds\":[]}";
    var source = try DeviceMediaSource.init(arena.allocator(), &.{albumSource("all")}, host.requester());

    try source.deleteItems(arena.allocator(), &.{ "one", "two" });

    try std.testing.expectEqualStrings("mediaLibraryDelete", host.last_method);
    try std.testing.expectEqualStrings("{\"itemIds\":[\"one\",\"two\"]}", host.last_request);
}

test "a delete the library refused names the items that are still on the device" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = newHost(arena.allocator());
    host.delete_reply = "{\"deletedIds\":[\"one\"],\"failedIds\":[\"two\"]}";
    var source = try DeviceMediaSource.init(arena.allocator(), &.{albumSource("all")}, host.requester());

    try std.testing.expectError(error.Thrown, source.deleteItems(arena.allocator(), &.{ "one", "two" }));

    try std.testing.expect(MediaSourceDeleteError.isInstance(error.Thrown));
    try std.testing.expectEqual(@as(usize, 1), MediaSourceDeleteError.sourceIds().len);
    try std.testing.expectEqualStrings("two", MediaSourceDeleteError.sourceIds()[0]);
}

// The import task reaches the library only through IMediaSource, so the source the builder makes is driven through it here.
test "buildDeviceMediaSource: the source it builds lists, opens, closes and deletes through the media source interface" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var host = newHost(allocator);
    var generator: utils.test_uuid_generator.TestUuidGenerator = .{};
    const source = try mobile_worker.device_media_source.buildDeviceMediaSource(allocator, &.{albumSource("cam")}, .{
        .sessionTempDir = "/tmp/session",
        .uuidGenerator = generator.uuidGenerator(),
        .hostRequester = host.requester(),
    });

    const page = try source.listPage(allocator, std.testing.io, null, 50);
    try std.testing.expectEqual(@as(usize, 1), page.items.len);
    try std.testing.expectEqualStrings("1", page.items[0].sourceId);
    try std.testing.expectEqualStrings("mediaLibraryList", host.last_method);

    try std.testing.expectEqualStrings("/cache/.media-tmp/1.jpg", try source.openItem(allocator, std.testing.io, page.items[0]));
    try std.testing.expectEqualStrings("mediaLibraryOpen", host.last_method);

    try source.closeItem(allocator, std.testing.io, page.items[0]);
    try std.testing.expectEqualStrings("mediaLibraryClose", host.last_method);

    try source.deleteItems(allocator, std.testing.io, &.{"1"});
    try std.testing.expectEqualStrings("mediaLibraryDelete", host.last_method);
    try std.testing.expectEqualStrings("{\"itemIds\":[\"1\"]}", host.last_request);
}

test "DeviceMediaSource: an unreadable open answer is an error naming the request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = newHost(arena.allocator());
    host.open_reply = "not json";
    var source = try DeviceMediaSource.init(arena.allocator(), &.{}, host.requester());
    const page = try source.listPage(arena.allocator(), null, 50);
    try std.testing.expectError(error.Thrown, source.openItem(arena.allocator(), page.items[0]));
    try std.testing.expect(std.mem.indexOf(u8, errors.lastErrorMessage(), "mediaLibraryOpen") != null);
}

test "DeviceMediaSource: an unreadable delete answer is an error naming the request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = newHost(arena.allocator());
    host.delete_reply = "not json";
    var source = try DeviceMediaSource.init(arena.allocator(), &.{}, host.requester());
    try std.testing.expectError(error.Thrown, source.deleteItems(arena.allocator(), &.{"1"}));
    try std.testing.expect(std.mem.indexOf(u8, errors.lastErrorMessage(), "mediaLibraryDelete") != null);
}
