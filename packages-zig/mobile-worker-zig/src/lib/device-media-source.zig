//
// The device photo library, presented as a media source.
//
// This is what lets the automatic import task run unchanged on a phone: the task only ever talks to IMediaSource, and this is the
// phone's implementation of it, as FolderMediaSource is the desktop's. The library is reached through the host requests
// mediaLibraryList, mediaLibraryOpen, mediaLibraryClose and mediaLibraryDelete, which the phone's native app answers.
//

const std = @import("std");
const utils = @import("utils-zig");
const api = @import("api-zig");
const node_api = @import("node-api-zig");

const errors = utils.errors;
const IHostRequester = utils.host_requester.IHostRequester;
const IAutoImportSource = api.auto_import_settings.IAutoImportSource;
const IMediaItem = api.media_source.IMediaItem;
const IMediaSource = api.media_source.IMediaSource;
const IMediaSourceListPage = api.media_source.IMediaSourceListPage;
const MediaSourceDeleteError = api.media_source.MediaSourceDeleteError;
const IMediaSourceBuildOptions = node_api.media_source_registry.IMediaSourceBuildOptions;

//
// One item in the library, as the native app describes it.
//
const IListedItem = struct {
    // The platform's own identifier for the item.
    id: []const u8,

    // What to show the user while this item is being imported.
    displayName: []const u8,

    // The item's MIME type.
    mimeType: []const u8,

    // The item's size in bytes.
    size: u64,

    // When the item was created, in milliseconds since the epoch.
    createdAtMs: i64,

    // The album the item belongs to, or an empty string when it claims none.
    albumId: []const u8,
};

//
// One page of the library, as the native app describes it.
//
const IListedPage = struct {
    // The items in the page.
    items: []const IListedItem,

    // Where the next page starts, absent at the end of the library.
    nextCursor: ?[]const u8 = null,
};

//
// What the native app answers mediaLibraryDelete with.
//
const IDeleteReply = struct {
    // The items that were deleted.
    deletedIds: []const []const u8,

    // The items that were not, because the user declined the system confirmation or the platform refused.
    failedIds: []const []const u8,
};

//
// A media source over the device photo library.
//
pub const DeviceMediaSource = struct {
    // The albums to take items from. Empty means the whole library.
    albumIds: []const []const u8,

    // Asks the phone's native app for the library.
    host: IHostRequester,

    //
    // Makes the source for the configured device sources. The reserved "everything" id is not an album to filter by: a list that
    // includes it covers the whole library, which is what a user gets before they choose albums.
    //
    pub fn init(allocator: std.mem.Allocator, sources: []const IAutoImportSource, host: IHostRequester) !DeviceMediaSource {
        var wantedAlbumIds: std.ArrayList([]const u8) = .empty;
        for (sources) |source| {
            const albumId = source.@"device-album".albumId;
            if (std.mem.eql(u8, albumId, api.auto_import_settings.ALL_DEVICE_MEDIA_ALBUM_ID)) {
                return .{
                    .albumIds = &.{},
                    .host = host,
                };
            }
            if (albumId.len > 0) {
                try wantedAlbumIds.append(allocator, albumId);
            }
        }
        return .{
            .albumIds = wantedAlbumIds.items,
            .host = host,
        };
    }

    //
    // The IMediaSource interface for this source (the source must not move while it is used).
    //
    pub fn mediaSource(self: *DeviceMediaSource) IMediaSource {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // The IMediaSource functions of this source.
    //
    const vtable: IMediaSource.VTable = .{
        .listPage = listPageErased,
        .openItem = openItemErased,
        .closeItem = closeItemErased,
        .deleteItems = deleteItemsErased,
    };

    //
    // Whether an item is one this source offers: any item when no albums are named, otherwise the items of the named albums.
    //
    pub fn isWanted(self: *const DeviceMediaSource, albumId: []const u8) bool {
        if (self.albumIds.len == 0) {
            return true;
        }
        for (self.albumIds) |wanted| {
            if (std.mem.eql(u8, wanted, albumId)) {
                return true;
            }
        }
        return false;
    }

    //
    // Returns one page of the library. A page that the album filter empties still yields its cursor, so the walk carries on to the
    // next page rather than stopping at the first page that happened to hold nothing wanted.
    //
    pub fn listPage(self: *DeviceMediaSource, allocator: std.mem.Allocator, cursor: ?[]const u8, pageSize: usize) !IMediaSourceListPage {
        const request = try std.json.Stringify.valueAlloc(allocator, .{
            .cursor = cursor orelse "",
            .pageSize = pageSize,
        }, .{});
        const reply = try self.host.call(allocator, "mediaLibraryList", request);
        const page = std.json.parseFromSliceLeaky(IListedPage, allocator, reply, .{
            .ignore_unknown_fields = true,
        }) catch {
            return errors.throwError("The phone's answer to mediaLibraryList could not be read.", .{});
        };
        var items: std.ArrayList(IMediaItem) = .empty;
        for (page.items) |item| {
            if (!self.isWanted(item.albumId)) {
                continue;
            }
            try items.append(allocator, .{
                .sourceId = item.id,
                // The path is only known once the item has been opened, which the task does just before handing the item to the
                // import. Until then there is nothing to read.
                .filePath = "",
                .displayName = item.displayName,
                .contentType = item.mimeType,
                .size = item.size,
                .createdAt = item.createdAtMs,
            });
        }
        return .{
            .items = items.items,
            .nextCursor = page.nextCursor,
        };
    }

    //
    // Copies the item out of the photo library into the app's storage and returns the path the import can read it from. A library
    // item is not a file the import can open, which is why this exists.
    //
    pub fn openItem(self: *DeviceMediaSource, allocator: std.mem.Allocator, item: IMediaItem) ![]const u8 {
        const request = try std.json.Stringify.valueAlloc(allocator, .{
            .itemId = item.sourceId,
        }, .{});
        const reply = try self.host.call(allocator, "mediaLibraryOpen", request);
        const parsed = std.json.parseFromSliceLeaky([]const u8, allocator, reply, .{}) catch {
            return errors.throwError("The phone's answer to mediaLibraryOpen could not be read.", .{});
        };
        return parsed;
    }

    //
    // Deletes the copy the open made. The item itself is untouched: removing it from the device is cleanup, and is a separate,
    // confirmed operation.
    //
    pub fn closeItem(self: *DeviceMediaSource, allocator: std.mem.Allocator, item: IMediaItem) !void {
        const request = try std.json.Stringify.valueAlloc(allocator, .{
            .itemId = item.sourceId,
        }, .{});
        _ = try self.host.call(allocator, "mediaLibraryClose", request);
    }

    //
    // Asks the platform to delete the named items from the photo library. The platform puts a system confirmation in front of
    // deleting media the app does not own, so this is one request per batch rather than one per photo. A user who declines, or a
    // platform that refuses, is reported through the error rather than passed over: the caller has to know which photos are still on
    // the device.
    //
    pub fn deleteItems(self: *DeviceMediaSource, allocator: std.mem.Allocator, sourceIds: []const []const u8) !void {
        const request = try std.json.Stringify.valueAlloc(allocator, .{
            .itemIds = sourceIds,
        }, .{});
        const replyText = try self.host.call(allocator, "mediaLibraryDelete", request);
        const reply = std.json.parseFromSliceLeaky(IDeleteReply, allocator, replyText, .{
            .ignore_unknown_fields = true,
        }) catch {
            return errors.throwError("The phone's answer to mediaLibraryDelete could not be read.", .{});
        };
        if (reply.failedIds.len > 0) {
            return MediaSourceDeleteError.throw(reply.failedIds, "The photo library did not delete {d} item(s).", .{reply.failedIds.len});
        }
    }

    //
    // The IMediaSource listPage of this source, called through the interface.
    //
    fn listPageErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, cursor: ?[]const u8, pageSize: usize) anyerror!IMediaSourceListPage {
        _ = io;
        const self: *DeviceMediaSource = @ptrCast(@alignCast(ptr));
        return self.listPage(allocator, cursor, pageSize);
    }

    //
    // The IMediaSource openItem of this source, called through the interface.
    //
    fn openItemErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, item: IMediaItem) anyerror![]const u8 {
        _ = io;
        const self: *DeviceMediaSource = @ptrCast(@alignCast(ptr));
        return self.openItem(allocator, item);
    }

    //
    // The IMediaSource closeItem of this source, called through the interface.
    //
    fn closeItemErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, item: IMediaItem) anyerror!void {
        _ = io;
        const self: *DeviceMediaSource = @ptrCast(@alignCast(ptr));
        return self.closeItem(allocator, item);
    }

    //
    // The IMediaSource deleteItems of this source, called through the interface.
    //
    fn deleteItemsErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, sourceIds: []const []const u8) anyerror!void {
        _ = io;
        const self: *DeviceMediaSource = @ptrCast(@alignCast(ptr));
        return self.deleteItems(allocator, sourceIds);
    }
};

//
// Builds the media source covering every configured device source. It needs the host requester of the task, and a program without
// one (every desktop) has no photo library to read, which is an error naming that.
//
pub fn buildDeviceMediaSource(allocator: std.mem.Allocator, sources: []const IAutoImportSource, options: IMediaSourceBuildOptions) anyerror!IMediaSource {
    const host = options.hostRequester orelse {
        return errors.throwError("The device photo library can only be read in the Photosphere app on a phone.", .{});
    };
    const source = try allocator.create(DeviceMediaSource);
    source.* = try DeviceMediaSource.init(allocator, sources, host);
    return source.mediaSource();
}

//
// Registers the builder for the device photo library, for the platform that can serve it.
//
pub fn registerDeviceMediaSourceBuilder() !void {
    try node_api.media_source_registry.registerMediaSourceBuilder("device-album", buildDeviceMediaSource);
}
