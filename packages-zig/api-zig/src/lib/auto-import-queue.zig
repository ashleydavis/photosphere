const std = @import("std");
const media_source = @import("media-source.zig");
const IMediaItem = media_source.IMediaItem;

//
// Holds the media the auto-import task has been offered and hands it out one item at a time.
//
// One queue, and nothing in it waits on a clock.
//
// There used to be two, and a rate limit. A "fast lane" was meant to carry photos a watcher had
// just reported, ahead of a "backfill lane" carrying the library that already existed, which was
// released at a fixed number of items a minute so that importing years of photos would not make the
// machine unusable. Both halves of that turned out to be untrue of this codebase: nothing ever put
// anything in the fast lane, because there is no watcher and never was, so every photo went through
// the paced lane; and no measurement was ever taken of the machine being made unusable, before or
// after. The limit was the whole reason an import of a real library took forty-five minutes.
//
// So there is one queue and no pacing. New photos are found by the scan reading the source from the
// start again on its next run, which is the only mechanism there has ever been.
//
pub const AutoImportQueue = struct {
    // Allocates the queue's lists (normally an arena).
    allocator: std.mem.Allocator,

    // Items waiting to be imported, oldest offer first.
    waiting: std.ArrayList(IMediaItem) = .empty,

    // The index of the oldest waiting item in `waiting` (the items before it have been released).
    waitingHead: usize = 0,

    // Every source id that has been queued, so re-listing a source (which happens on every poll)
    // does not queue the same item a second time.
    queuedSourceIds: std.StringHashMapUnmanaged(void) = .empty,

    //
    // Creates an empty queue.
    //
    pub fn init(allocator: std.mem.Allocator) AutoImportQueue {
        return .{
            .allocator = allocator,
        };
    }

    //
    // Offers items to the queue. Returns how many were accepted; the rest were already queued.
    //
    pub fn addItems(self: *AutoImportQueue, items: []const IMediaItem) !usize {
        var accepted: usize = 0;
        for (items) |item| {
            if (self.queuedSourceIds.contains(item.sourceId)) {
                continue;
            }
            try self.queuedSourceIds.put(self.allocator, try self.allocator.dupe(u8, item.sourceId), {});
            try self.waiting.append(self.allocator, item);
            accepted += 1;
        }

        return accepted;
    }

    //
    // Returns the item that should be imported next, or undefined when nothing is waiting.
    //
    pub fn nextItem(self: *AutoImportQueue) ?IMediaItem {
        if (self.waitingHead >= self.waiting.items.len) {
            return null;
        }
        const item = self.waiting.items[self.waitingHead];
        self.waitingHead += 1;
        return item;
    }

    //
    // True while there are items waiting to be released. The scan uses this to know when to ask the
    // source for its next page, so the cursor does not run ahead of what has been imported.
    //
    pub fn hasPending(self: *const AutoImportQueue) bool {
        return self.pendingCount() > 0;
    }

    //
    // How many items are waiting and not yet released.
    //
    pub fn pendingCount(self: *const AutoImportQueue) usize {
        return self.waiting.items.len - self.waitingHead;
    }
};
