//
// Everything the example adds to Ziggy's core: its channels and its task types.
//

const ziggy = @import("ziggy-core");
const channels = @import("lib/channels.zig");
const hello_tasks = @import("lib/hello-tasks.zig");
pub const media_server = @import("lib/media-server.zig");
const menu = @import("lib/menu.zig");
const page_query = @import("lib/page-query.zig");
const pickers = @import("lib/pickers.zig");
const app_state = @import("lib/app-state.zig");
const page = @import("page-files");

//
// The example's channels and task types, and the state, observers and error describer it gives the core.
//
pub const app = ziggy.core.AppHandlers{
    .channels = &[_]ziggy.core.ChannelEntry{
        .{
            .name = "ping",
            .handler = channels.pingHandler,
        },
        .{
            .name = "payload-stats",
            .handler = channels.payloadStatsHandler,
        },
        .{
            .name = "file-roundtrip",
            .handler = channels.fileRoundtripHandler,
        },
        .{
            .name = "fail",
            .handler = channels.failHandler,
        },
        .{
            .name = "refuse",
            .handler = app_state.refuseHandler,
        },
        .{
            .name = "task-stats",
            .handler = app_state.taskStatsHandler,
        },
        .{
            .name = "queue-from-app",
            .handler = app_state.queueFromAppHandler,
        },
        .{
            .name = "cancel-from-app",
            .handler = app_state.cancelFromAppHandler,
        },
    },
    .state = app_state.state_hooks,
    .on_task_end = app_state.onTaskEnd,
    .on_task_message = app_state.onTaskMessage,
    .describe_error = app_state.describeError,
    .menu_json = menu.menu_json,
    .ui_files = &page.files,
    .page_query = page_query.pageQuery,
    .task_channels = &[_]ziggy.core.TaskChannelEntry{
        .{
            .name = "pick-folder",
            .task_type = "pick-folder",
        },
        .{
            .name = "pick-files",
            .task_type = "pick-files",
        },
        .{
            .name = "pick-file",
            .task_type = "pick-file",
        },
    },
    .tasks = &[_]ziggy.task_runner.TaskHandlerEntry{
        .{
            .name = "hello-short",
            .handler = hello_tasks.helloShortHandler,
        },
        .{
            .name = "hello-long",
            .handler = hello_tasks.helloLongHandler,
        },
        .{
            .name = "hello-child",
            .handler = hello_tasks.helloChildHandler,
        },
        .{
            .name = "hello-fail",
            .handler = hello_tasks.helloFailHandler,
        },
        .{
            .name = "os-version",
            .handler = hello_tasks.osVersionHandler,
        },
        .{
            .name = "describe-self",
            .handler = app_state.describeSelfHandler,
        },
        .{
            .name = "run-in-turn",
            .handler = app_state.runInTurnHandler,
        },
        .{
            .name = "media-server",
            .handler = media_server.mediaServerHandler,
        },
        .{
            .name = "background-keep-alive",
            .handler = hello_tasks.backgroundCountHandler,
            .kind = .keep_alive,
        },
        .{
            .name = "background-normal",
            .handler = hello_tasks.backgroundCountHandler,
        },
        .{
            .name = "pick-folder",
            .handler = pickers.pickFolderHandler,
        },
        .{
            .name = "pick-files",
            .handler = pickers.pickFilesHandler,
        },
        .{
            .name = "pick-file",
            .handler = pickers.pickFileHandler,
        },
    },
};
