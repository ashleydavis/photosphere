const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const task_queue_zig = @import("ziggy").task_queue;
const load_assets_types = @import("load-assets.types.zig");
const TaskQueue = task_queue_zig.task_queue.TaskQueue;
const ILoadAssetsData = load_assets_types.ILoadAssetsData;

//
// Loads assets from the database using a background task.
// The task will stream batches of assets to the client via task events.
//
// Interactive, because this is what a tap on a database is waiting for: until it has streamed its
// first page the user is looking at an empty gallery. Queued behind an automatic import's backlog it
// took two minutes and eight seconds to open a database of 2,300 photos on a Pixel 6.
//
// loadId identifies this one load, and the caller must also build the queue it passes with this id as
// its source. It is deliberately not the database path: a cancel takes a source, so a load tagged with
// the path is cancelled by anything that cancels that path, which is every other load of the same
// database. A cancelled load stops paging and reports success with no assets, so cancelling a
// superseded load of a database killed the replacement and both reported 0 assets, leaving the gallery
// empty. Smoke test 26, s3-database-lifecycle, failed that way on Windows and macOS.
//
pub fn loadAssets(allocator: std.mem.Allocator, io: std.Io, log: ILog, queue: *TaskQueue, databasePath: []const u8, loadId: []const u8) !void {
    const data: ILoadAssetsData = .{
        .databasePath = databasePath,
        .job = .{
            .id = try std.fmt.allocPrint(allocator, "load:{s}", .{databasePath}),
            .name = "Loading assets",
            .cancelSource = loadId,
        },
    };
    const text = try std.json.Stringify.valueAlloc(allocator, data, .{
        .emit_null_optional_fields = false,
    });
    const dataValue = try std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
    _ = try queue.addTask(io, allocator, log, "load-assets", dataValue, loadId, .Interactive);
}
