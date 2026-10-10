const std = @import("std");
const task_queue_zig = @import("task-queue-zig");
const IJobTag = task_queue_zig.types.IJobTag;

//
// Input data for the load-assets background task.
// (Zig: task data travels as JSON (std.json.Value); the defaults let std.json parse data that leaves keys out, so the
// handler can refuse a missing databasePath with its own message.)
//
pub const ILoadAssetsData = struct {
    //
    // The path of the database to load the assets of.
    //
    databasePath: []const u8 = "",

    //
    // Names the job this task belongs to, so the load shows up in the interface's job list.
    //
    job: ?IJobTag = null,
};

//
// Result of the load-assets background task.
//
pub const ILoadAssetsResult = struct {
    //
    // How many assets were sent in all.
    //
    totalAssets: u64,

    //
    // How many asset-page messages were sent.
    //
    batchesSent: u64,
};

//
// Task message that carries one page of assets to the interface.
// (Zig: the assets are the JSON values of their records, as task messages are JSON.)
//
pub const IAssetPageMessage = struct {
    //
    // Message type discriminator ("asset-page").
    //
    type: []const u8,

    //
    // The database path this batch belongs to. Used by the frontend to discard messages
    // that arrive after the database has been switched or closed.
    //
    databasePath: []const u8,

    //
    // The assets of the page.
    //
    batch: []const std.json.Value,
};
