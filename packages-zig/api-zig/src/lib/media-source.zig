//
// The abstraction the auto-import task scans through.
//
// A media source is somewhere media arrives: a folder on a desktop machine, or the device photo
// library on a phone. The auto-import task only ever talks to this interface, so the same task runs
// unchanged on the CLI, on the desktop and on mobile, and adding a new kind of source does not touch
// the task at all.
//

const std = @import("std");
const utils = @import("utils-zig");
const errors = utils.errors;

//
// One piece of media offered by a source.
//
pub const IMediaItem = struct {
    // Identifies this item within its source and does not change between listings. A folder source
    // uses the file's logical path; a device library uses the platform's asset identifier. The
    // auto-import cursor is recorded in terms of these, so it has to be stable across a restart.
    sourceId: []const u8,

    // Where the importer can read the bytes. Absolute on desktop, sandbox-relative on mobile. For a
    // source that materialises a temporary copy this is only valid between openItem and
    // closeItem.
    filePath: []const u8,

    // What to show the user while this item is being imported.
    displayName: []const u8,

    // The MIME type of the item.
    contentType: []const u8,

    // The size of the item in bytes.
    size: u64,

    // When the item was created, as far as the source can tell (milliseconds since the epoch, like
    // the time of a JavaScript Date).
    createdAt: i64,
};

//
// One page of a source listing.
//
pub const IMediaSourceListPage = struct {
    // The items in this page, in the source's stable listing order.
    items: []const IMediaItem,

    // Where the next page starts. Undefined at the end of the listing.
    nextCursor: ?[]const u8,
};

//
// Somewhere media arrives that automatic import lists and imports from.
//
pub const IMediaSource = struct {
    // Pointer to the implementation.
    ptr: *anyopaque,

    // The implementation's functions.
    vtable: *const VTable,

    //
    // The functions an implementation of IMediaSource provides.
    //
    pub const VTable = struct {
        // Returns one page of the source's contents.
        listPage: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, cursor: ?[]const u8, pageSize: usize) anyerror!IMediaSourceListPage,

        // Returns a path the importer can read the item's bytes from.
        openItem: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, item: IMediaItem) anyerror![]const u8,

        // Releases whatever openItem materialised.
        closeItem: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, item: IMediaItem) anyerror!void,

        // Deletes the named items from the source.
        deleteItems: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, sourceIds: []const []const u8) anyerror!void,
    };

    //
    // Returns one page of the source's contents. Pass undefined as the cursor to start at the
    // beginning, and the previous page's nextCursor to continue.
    //
    pub fn listPage(self: IMediaSource, allocator: std.mem.Allocator, io: std.Io, cursor: ?[]const u8, pageSize: usize) anyerror!IMediaSourceListPage {
        return self.vtable.listPage(self.ptr, allocator, io, cursor, pageSize);
    }

    //
    // Returns a path the importer can read the item's bytes from. A source whose items are already
    // files returns the path unchanged; one that has to materialise a copy makes it here.
    //
    pub fn openItem(self: IMediaSource, allocator: std.mem.Allocator, io: std.Io, item: IMediaItem) anyerror![]const u8 {
        return self.vtable.openItem(self.ptr, allocator, io, item);
    }

    //
    // Releases whatever openItem materialised. Does nothing for a source whose items are already
    // files.
    //
    pub fn closeItem(self: IMediaSource, allocator: std.mem.Allocator, io: std.Io, item: IMediaItem) anyerror!void {
        return self.vtable.closeItem(self.ptr, allocator, io, item);
    }

    //
    // Deletes the named items from the source. Throws MediaSourceDeleteError naming the items it
    // could not delete, rather than reporting success for work that did not happen.
    //
    pub fn deleteItems(self: IMediaSource, allocator: std.mem.Allocator, io: std.Io, sourceIds: []const []const u8) anyerror!void {
        return self.vtable.deleteItems(self.ptr, allocator, io, sourceIds);
    }
};

//
// Allocator for the source ids the most recent MediaSourceDeleteError carries (they outlive the call
// that threw it).
//
const delete_error_allocator = std.heap.smp_allocator;

//
// The source ids of the most recent MediaSourceDeleteError thrown on this thread (a Zig error cannot
// carry them; see errors.zig for how the message is carried).
//
threadlocal var lastDeleteErrorSourceIds: std.ArrayList([]const u8) = .empty;

//
// Thrown when a source is asked to delete items it cannot delete. It names them, so the caller can
// report which source files are still on the device rather than assuming they are gone.
// (Zig: `throw new MediaSourceDeleteError(message, sourceIds)` is written
// `return MediaSourceDeleteError.throw(sourceIds, format, args)`, and the ids are read back with
// `MediaSourceDeleteError.sourceIds()` where TypeScript reads `error.sourceIds`.)
//
pub const MediaSourceDeleteError = struct {
    //
    // Equivalent of `throw new MediaSourceDeleteError(message, sourceIds)`.
    //
    pub fn throw(undeletableSourceIds: []const []const u8, comptime format: []const u8, args: anytype) !void {
        for (lastDeleteErrorSourceIds.items) |sourceId| {
            delete_error_allocator.free(sourceId);
        }
        lastDeleteErrorSourceIds.clearRetainingCapacity();
        for (undeletableSourceIds) |sourceId| {
            try lastDeleteErrorSourceIds.append(delete_error_allocator, try delete_error_allocator.dupe(u8, sourceId));
        }
        errors.recordError("MediaSourceDeleteError", format, args);
        return error.Thrown;
    }

    //
    // Equivalent of `error instanceof MediaSourceDeleteError` for the most recent error.
    //
    pub fn isInstance(err: anyerror) bool {
        return err == error.Thrown and std.mem.eql(u8, errors.lastErrorName(), "MediaSourceDeleteError");
    }

    //
    // The source ids that could not be deleted (TypeScript: `error.sourceIds`), valid until the next
    // MediaSourceDeleteError is thrown on this thread.
    //
    pub fn sourceIds() []const []const u8 {
        return lastDeleteErrorSourceIds.items;
    }
};
