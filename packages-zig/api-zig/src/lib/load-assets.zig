const std = @import("std");
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
pub fn loadAssets(allocator: std.mem.Allocator, io: std.Io, queue: *TaskQueue, databasePath: []const u8) !void {
    const data: ILoadAssetsData = .{
        .databasePath = databasePath,
        .job = .{
            .id = try std.fmt.allocPrint(allocator, "load:{s}", .{databasePath}),
            .name = "Loading assets",
            .cancelSource = databasePath,
        },
    };
    const text = try std.json.Stringify.valueAlloc(allocator, data, .{
        .emit_null_optional_fields = false,
    });
    const dataValue = try std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
    _ = try queue.addTask(io, allocator, "load-assets", dataValue, databasePath, .Interactive);
}
