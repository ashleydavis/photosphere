//
// The helpers that Ziggy's task queue is written with are taken from Ziggy's core, so that Photosphere and the task queue share one
// copy of their types and of the state they keep (the log, the last error, the process environment and the console). The files of
// those helpers here are not used.
//
const ziggy_utils = @import("ziggy-core").task_queue.utils;

pub const exit_codes = @import("lib/exit-codes.zig");
pub const termination = @import("lib/termination.zig");
pub const exec = ziggy_utils.exec;
pub const in_process_tools = ziggy_utils.in_process_tools;
pub const test_uuid_generator = ziggy_utils.file_test_uuid_generator;
pub const test_timestamp_provider = ziggy_utils.test_timestamp_provider;
pub const fs = @import("lib/fs.zig");
pub const path = ziggy_utils.path;
pub const node_fs = @import("lib/node-fs.zig");
pub const toml = @import("lib/toml.zig");
pub const process_env = ziggy_utils.process_env;
pub const yaml = @import("lib/yaml.zig");
pub const photo_folders = @import("lib/photo-folders.zig");
pub const http_server = @import("lib/http-server.zig");
