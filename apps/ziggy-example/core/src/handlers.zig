//
// Everything the example adds to Ziggy's core: its channels and its task types.
//

const ziggy = @import("ziggy-core");
const channels = @import("lib/channels.zig");
const hello_tasks = @import("lib/hello-tasks.zig");
const menu = @import("lib/menu.zig");
const pickers = @import("lib/pickers.zig");

//
// The example's channels and task types.
//
pub const app = ziggy.core.AppHandlers{
    .channels = &[_]ziggy.core.ChannelEntry{
        .{ .name = "ping", .handler = channels.pingHandler },
        .{ .name = "payload-stats", .handler = channels.payloadStatsHandler },
        .{ .name = "file-roundtrip", .handler = channels.fileRoundtripHandler },
        .{ .name = "fail", .handler = channels.failHandler },
    },
    .menu_json = menu.menu_json,
    .task_channels = &[_]ziggy.core.TaskChannelEntry{
        .{ .name = "pick-folder", .task_type = "pick-folder" },
        .{ .name = "pick-files", .task_type = "pick-files" },
        .{ .name = "pick-file", .task_type = "pick-file" },
    },
    .tasks = &[_]ziggy.task_runner.TaskHandlerEntry{
        .{ .name = "hello-short", .handler = hello_tasks.helloShortHandler },
        .{ .name = "hello-long", .handler = hello_tasks.helloLongHandler },
        .{ .name = "hello-child", .handler = hello_tasks.helloChildHandler },
        .{ .name = "hello-fail", .handler = hello_tasks.helloFailHandler },
        .{ .name = "os-version", .handler = hello_tasks.osVersionHandler },
        .{ .name = "pick-folder", .handler = pickers.pickFolderHandler },
        .{ .name = "pick-files", .handler = pickers.pickFilesHandler },
        .{ .name = "pick-file", .handler = pickers.pickFileHandler },
    },
};
