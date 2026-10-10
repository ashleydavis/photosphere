const std = @import("std");
const utils = @import("utils-zig");
const api = @import("api-zig");
const media_source = @import("media-source.zig");
const errors = utils.errors;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const IAutoImportSource = api.auto_import_settings.IAutoImportSource;
const IMediaItem = media_source.IMediaItem;
const IMediaSource = media_source.IMediaSource;
const IMediaSourceListPage = media_source.IMediaSourceListPage;

//
// How the auto-import task turns the configured sources into something it can read from.
//
// The task cannot import the implementations directly, because the folder implementation lives here
// in node-api and the device photo library implementation lives in the mobile worker package.
// Instead each platform registers a builder for the source types it can serve, and the task asks
// for whatever the settings name. A source type nobody registered fails loudly rather than being
// quietly skipped, because skipping it would mean silently backing up none of the user's photos.
//

//
// What a builder needs besides the sources themselves.
//
pub const IMediaSourceBuildOptions = struct {
    // A directory the source may use for temporary files, such as media exported out of the device
    // photo library or extracted from a zip archive.
    sessionTempDir: []const u8,

    // Generates names for those temporary files.
    uuidGenerator: IUuidGenerator,

    // Reaches the phone's shell, for a source only the phone can read (the device photo library). Null where there is no phone shell.
    hostRequester: ?utils.host_requester.IHostRequester,
};

//
// Builds one media source covering every configured source of a single type.
// The source is allocated with the allocator, which it uses for as long as it lives.
//
pub const IMediaSourceBuilder = *const fn (allocator: std.mem.Allocator, sources: []const IAutoImportSource, options: IMediaSourceBuildOptions) anyerror!IMediaSource;

//
// The builders registered by this platform, by source type.
// Process-wide and guarded by mediaSourceBuildersLock, because every worker thread shares it; the
// types are static strings.
//
var mediaSourceBuilders: std.StringArrayHashMapUnmanaged(IMediaSourceBuilder) = .empty;

//
// Guards mediaSourceBuilders, which every worker thread shares.
//
var mediaSourceBuildersLock: std.atomic.Mutex = .unlocked;

//
// Takes mediaSourceBuildersLock.
//
fn lockBuilders() void {
    while (!mediaSourceBuildersLock.tryLock()) {
        std.atomic.spinLoopHint();
    }
}

//
// Registers the builder for a source type. Called once per type at startup by the platform that can
// serve it: node-api registers folders, the mobile worker registers the device photo library.
//
pub fn registerMediaSourceBuilder(sourceType: []const u8, builder: IMediaSourceBuilder) !void {
    lockBuilders();
    defer mediaSourceBuildersLock.unlock();
    try mediaSourceBuilders.put(std.heap.smp_allocator, sourceType, builder);
}

//
// Forgets every registered builder. For tests, so one test's registration does not leak into the
// next.
//
pub fn clearMediaSourceBuilders() void {
    lockBuilders();
    defer mediaSourceBuildersLock.unlock();
    mediaSourceBuilders.clearRetainingCapacity();
}

//
// The builder registered for a source type, or null.
//
fn getMediaSourceBuilder(sourceType: []const u8) ?IMediaSourceBuilder {
    lockBuilders();
    defer mediaSourceBuildersLock.unlock();
    return mediaSourceBuilders.get(sourceType);
}

//
// Builds a single media source covering every configured source, whatever their types.
//
pub fn buildMediaSource(allocator: std.mem.Allocator, sources: []const IAutoImportSource, options: IMediaSourceBuildOptions) !IMediaSource {
    if (sources.len == 0) {
        return errors.throwError("Cannot build a media source: no automatic import sources are configured.", .{});
    }

    var sourcesByType: std.StringArrayHashMapUnmanaged(std.ArrayList(IAutoImportSource)) = .empty;
    for (sources) |source| {
        const existing = try sourcesByType.getOrPut(allocator, source.sourceType());
        if (existing.found_existing) {
            try existing.value_ptr.append(allocator, source);
        }
        else {
            existing.value_ptr.* = .empty;
            try existing.value_ptr.append(allocator, source);
        }
    }

    var built: std.ArrayList(IMediaSource) = .empty;
    var iterator = sourcesByType.iterator();
    while (iterator.next()) |entry| {
        const sourceType = entry.key_ptr.*;
        const sourcesOfType = entry.value_ptr.items;
        const builder = getMediaSourceBuilder(sourceType) orelse {
            return errors.throwError("No media source builder is registered for source type \"{s}\" on this platform.", .{sourceType});
        };
        try built.append(allocator, try builder(allocator, sourcesOfType, options));
    }

    if (built.items.len == 1) {
        return built.items[0];
    }
    const composite = try allocator.create(CompositeMediaSource);
    composite.* = CompositeMediaSource.init(try built.toOwnedSlice(allocator));
    return composite.mediaSource();
}

//
// A position inside a composite listing: which child, and where in that child.
//
const ICompositeCursor = struct {
    // Index of the child source the listing has reached.
    childIndex: usize,

    // The child's own cursor, or null at the start of that child.
    childCursor: ?[]const u8,
};

//
// A source id together with the child it belongs to.
//
const IStampedSourceId = struct {
    // Index of the child source the id came from.
    childIndex: usize,

    // The child's own source id, with the stamp removed.
    sourceId: []const u8,
};

//
// Reads a child index the way a number is read from text: whole and not negative, or null.
//
fn parseChildIndexNumber(text: []const u8) ?usize {
    const childIndex = utils.js_number.stringToNumber(text);
    if (!std.math.isFinite(childIndex) or @floor(childIndex) != childIndex or childIndex < 0) {
        return null;
    }
    return @as(usize, @intFromFloat(childIndex));
}

//
// Splits a composite cursor into the index of the child it belongs to and that child's own cursor.
//
fn parseCompositeCursor(cursor: []const u8) !ICompositeCursor {
    const separatorIndex = std.mem.indexOfScalar(u8, cursor, '|') orelse {
        return errors.throwError("Malformed composite media source cursor: \"{s}\".", .{cursor});
    };
    const childIndex = parseChildIndexNumber(cursor[0..separatorIndex]) orelse {
        return errors.throwError("Malformed composite media source cursor: \"{s}\".", .{cursor});
    };
    const childCursor = cursor[separatorIndex + 1 ..];
    return .{
        .childIndex = childIndex,
        .childCursor = if (childCursor.len > 0) childCursor else null,
    };
}

//
// Records which child an item came from, in the only field that travels with it everywhere.
//
fn stampChildIndex(allocator: std.mem.Allocator, item: IMediaItem, childIndex: usize) !IMediaItem {
    var stamped = item;
    stamped.sourceId = try std.fmt.allocPrint(allocator, "{d}#{s}", .{ childIndex, item.sourceId });
    return stamped;
}

//
// Reads back the child index a source id was stamped with.
//
fn parseChildIndex(stampedSourceId: []const u8) !IStampedSourceId {
    const separatorIndex = std.mem.indexOfScalar(u8, stampedSourceId, '#') orelse {
        return errors.throwError("Source id \"{s}\" did not come from this composite media source.", .{stampedSourceId});
    };
    const childIndex = parseChildIndexNumber(stampedSourceId[0..separatorIndex]) orelse {
        return errors.throwError("Source id \"{s}\" did not come from this composite media source.", .{stampedSourceId});
    };
    return .{
        .childIndex = childIndex,
        .sourceId = stampedSourceId[separatorIndex + 1 ..],
    };
}

//
// A copy of an item carrying the child's own source id rather than the stamped one.
//
fn withSourceId(item: IMediaItem, sourceId: []const u8) IMediaItem {
    var copy = item;
    copy.sourceId = sourceId;
    return copy;
}

//
// Presents several media sources as one, by listing them one after another.
//
// This exists for the case where the settings name more than one kind of source at once. The usual
// case is a single kind, and then buildMediaSource returns that source directly rather than wrapping
// it.
//
pub const CompositeMediaSource = struct {
    // The sources being presented as one, listed in this order.
    sources: []const IMediaSource,

    //
    // Creates the composite over the given sources.
    //
    pub fn init(sources: []const IMediaSource) CompositeMediaSource {
        return .{
            .sources = sources,
        };
    }

    //
    // Gets the IMediaSource interface for this source (the source must not move while it is used).
    //
    pub fn mediaSource(self: *CompositeMediaSource) IMediaSource {
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
    // IMediaSource.listPage for this implementation.
    //
    fn listPageErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, cursor: ?[]const u8, pageSize: usize) anyerror!IMediaSourceListPage {
        const self: *CompositeMediaSource = @ptrCast(@alignCast(ptr));
        return self.listPage(allocator, io, cursor, pageSize);
    }

    //
    // IMediaSource.openItem for this implementation.
    //
    fn openItemErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, item: IMediaItem) anyerror![]const u8 {
        const self: *CompositeMediaSource = @ptrCast(@alignCast(ptr));
        return self.openItem(allocator, io, item);
    }

    //
    // IMediaSource.closeItem for this implementation.
    //
    fn closeItemErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, item: IMediaItem) anyerror!void {
        const self: *CompositeMediaSource = @ptrCast(@alignCast(ptr));
        return self.closeItem(allocator, io, item);
    }

    //
    // IMediaSource.deleteItems for this implementation.
    //
    fn deleteItemsErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, sourceIds: []const []const u8) anyerror!void {
        const self: *CompositeMediaSource = @ptrCast(@alignCast(ptr));
        return self.deleteItems(allocator, io, sourceIds);
    }

    //
    // Returns one page, moving on to the next child source when the current one runs out. Empty
    // children are skipped within the call rather than returning an empty page, which would look
    // like the end of the listing.
    //
    // Every item's source id is stamped with the child it came from, so a later export, release or
    // delete goes back to that child rather than being guessed at.
    //
    pub fn listPage(self: *CompositeMediaSource, allocator: std.mem.Allocator, io: std.Io, cursor: ?[]const u8, pageSize: usize) !IMediaSourceListPage {
        const position: ICompositeCursor = if (cursor) |cursorText|
            try parseCompositeCursor(cursorText)
        else
            .{
                .childIndex = 0,
                .childCursor = null,
            };

        var childIndex = position.childIndex;
        var childCursor = position.childCursor;

        while (childIndex < self.sources.len) {
            const page = try self.sources[childIndex].listPage(allocator, io, childCursor, pageSize);
            const items = try allocator.alloc(IMediaItem, page.items.len);
            for (page.items, 0..) |item, itemIndex| {
                items[itemIndex] = try stampChildIndex(allocator, item, childIndex);
            }

            if (page.nextCursor) |nextCursor| {
                return .{
                    .items = items,
                    .nextCursor = try std.fmt.allocPrint(allocator, "{d}|{s}", .{ childIndex, nextCursor }),
                };
            }

            // This child is finished. If it gave us items, hand them back and point at the next
            // child; otherwise carry straight on so an empty source does not end the listing.
            if (items.len > 0) {
                const nextChildIndex = childIndex + 1;
                return .{
                    .items = items,
                    .nextCursor = if (nextChildIndex < self.sources.len) try std.fmt.allocPrint(allocator, "{d}|", .{nextChildIndex}) else null,
                };
            }

            childIndex += 1;
            childCursor = null;
        }

        return .{
            .items = &.{},
            .nextCursor = null,
        };
    }

    //
    // Exports through the child the item came from.
    //
    pub fn openItem(self: *CompositeMediaSource, allocator: std.mem.Allocator, io: std.Io, item: IMediaItem) ![]const u8 {
        const stamped = try parseChildIndex(item.sourceId);
        const child = try self.childAt(stamped.childIndex);
        return child.openItem(allocator, io, withSourceId(item, stamped.sourceId));
    }

    //
    // Releases through the child the item came from.
    //
    pub fn closeItem(self: *CompositeMediaSource, allocator: std.mem.Allocator, io: std.Io, item: IMediaItem) !void {
        const stamped = try parseChildIndex(item.sourceId);
        const child = try self.childAt(stamped.childIndex);
        try child.closeItem(allocator, io, withSourceId(item, stamped.sourceId));
    }

    //
    // Deletes each id through the child it came from, so no child is ever handed another child's
    // ids.
    //
    pub fn deleteItems(self: *CompositeMediaSource, allocator: std.mem.Allocator, io: std.Io, sourceIds: []const []const u8) !void {
        var idsByChild: std.AutoArrayHashMapUnmanaged(usize, std.ArrayList([]const u8)) = .empty;
        for (sourceIds) |sourceId| {
            const stamped = try parseChildIndex(sourceId);
            const existing = try idsByChild.getOrPut(allocator, stamped.childIndex);
            if (!existing.found_existing) {
                existing.value_ptr.* = .empty;
            }
            try existing.value_ptr.append(allocator, stamped.sourceId);
        }

        var iterator = idsByChild.iterator();
        while (iterator.next()) |entry| {
            const child = try self.childAt(entry.key_ptr.*);
            try child.deleteItems(allocator, io, entry.value_ptr.items);
        }
    }

    //
    // The child at an index, or a loud failure when the index names no child. An id that arrived
    // from somewhere else must not be quietly handed to the wrong source.
    //
    fn childAt(self: *CompositeMediaSource, childIndex: usize) !IMediaSource {
        if (childIndex >= self.sources.len) {
            return errors.throwError("Composite media source has no child at index {d}.", .{childIndex});
        }
        return self.sources[childIndex];
    }
};
