const std = @import("std");
const utils = @import("utils-zig");
const media_source = @import("media-source.zig");
const errors = utils.errors;
const IMediaSource = media_source.IMediaSource;
const MediaSourceDeleteError = media_source.MediaSourceDeleteError;

//
// Deleting the source file off the device once the asset is safely in the local database.
//
// The rule this file exists to enforce is that nothing is deleted until it has been confirmed
// present in the database, by content hash, not merely reported as imported. A report is a message
// about what a task believed it did; the hash being in the database is the database saying so.
//

// Not ported: IImportedSourceItem, selectConfirmedForCleanup (not used by psi add).

//
// What a cleanup run actually did.
//
pub const ISourceCleanupResult = struct {
    // The source ids that were deleted.
    deletedSourceIds: []const []const u8,

    // The source ids the source refused or failed to delete.
    failedSourceIds: []const []const u8,
};

//
// Deletes the given source ids in batches.
//
// Mobile is the reason for the batching: Android and iOS both put a system confirmation in front of
// deleting media the app does not own, so one request per photo would mean one dialog per photo.
//
// A batch the source refuses does not stop the run: the remaining batches are still attempted, and
// every id that was not deleted comes back in the result so the caller can say what is still on the
// device instead of assuming it is gone.
//
pub fn runSourceCleanup(allocator: std.mem.Allocator, io: std.Io, source: IMediaSource, sourceIds: []const []const u8, batchSize: usize) !ISourceCleanupResult {
    if (batchSize < 1) {
        return errors.throwError("Source cleanup batch size must be at least 1, got {d}.", .{batchSize});
    }

    var deletedSourceIds: std.ArrayList([]const u8) = .empty;
    var failedSourceIds: std.ArrayList([]const u8) = .empty;

    var start: usize = 0;
    while (start < sourceIds.len) : (start += batchSize) {
        const batch = sourceIds[start..@min(start + batchSize, sourceIds.len)];
        if (source.deleteItems(allocator, io, batch)) {
            try deletedSourceIds.appendSlice(allocator, batch);
        }
        else |err| {
            if (MediaSourceDeleteError.isInstance(err)) {
                // The source named exactly what it could not delete, so the rest of the batch did go.
                const undeletable = MediaSourceDeleteError.sourceIds();
                for (batch) |sourceId| {
                    if (containsString(undeletable, sourceId)) {
                        try failedSourceIds.append(allocator, sourceId);
                    }
                    else {
                        try deletedSourceIds.append(allocator, sourceId);
                    }
                }
            }
            else {
                // The source failed in a way that says nothing about which items went, so none of
                // the batch may be reported as deleted.
                try failedSourceIds.appendSlice(allocator, batch);
            }
        }
    }

    return .{
        .deletedSourceIds = deletedSourceIds.items,
        .failedSourceIds = failedSourceIds.items,
    };
}

//
// True when the list holds the string (TypeScript: `new Set(error.sourceIds).has(sourceId)`).
// (No TypeScript counterpart.)
//
fn containsString(list: []const []const u8, value: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, value)) {
            return true;
        }
    }
    return false;
}
