const std = @import("std");
const utils = @import("utils-zig");
const api = @import("api-zig");
const media_source = @import("media-source.zig");
const errors = utils.errors;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const IAutoImportSource = api.auto_import_settings.IAutoImportSource;
const IMediaSource = media_source.IMediaSource;

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
};

//
// Builds one media source covering every configured source of a single type.
// (Zig: the source is allocated with the allocator, which it uses for as long as it lives.)
//
pub const IMediaSourceBuilder = *const fn (allocator: std.mem.Allocator, sources: []const IAutoImportSource, options: IMediaSourceBuildOptions) anyerror!IMediaSource;

//
// The builders registered by this platform, by source type.
// (Zig: process-wide and guarded by mediaSourceBuildersLock, because every worker thread shares it; the
// types are static strings.)
//
var mediaSourceBuilders: std.StringArrayHashMapUnmanaged(IMediaSourceBuilder) = .empty;

//
// Guards mediaSourceBuilders. (No TypeScript counterpart: each TypeScript worker has its own map.)
//
var mediaSourceBuildersLock: std.atomic.Mutex = .unlocked;

//
// Takes mediaSourceBuildersLock. (No TypeScript counterpart.)
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
// The builder registered for a source type, or null. (No TypeScript counterpart: `mediaSourceBuilders.get`.)
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
    return errors.throwError("Not ported: CompositeMediaSource (psi add only builds folder sources).", .{});
}

// Not ported: parseCompositeCursor, ICompositeCursor, CompositeMediaSource, stampChildIndex, parseChildIndex,
// withSourceId, IStampedSourceId (psi add only builds folder sources, which are one source type).
