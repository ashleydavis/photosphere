//
// The helpers and the log that Ziggy is written with are taken from Ziggy's utils and log, so that Photosphere and Ziggy share one
// copy of their types and of the state they keep (the log, the last error, the process environment and the console). The files of
// those helpers here are not used.
//
const ziggy_utils = @import("ziggy").utils;

pub const native_caller = ziggy_utils.native_caller;
pub const sleep = ziggy_utils.sleep;
pub const retry = @import("lib/retry.zig");
pub const uuid_generator = ziggy_utils.uuid_generator;
pub const random_uuid_generator = ziggy_utils.random_uuid_generator;
pub const test_uuid_generator = ziggy_utils.test_uuid_generator;
pub const wrapped_error = ziggy_utils.wrapped_error;
pub const fatal_error = @import("lib/fatal-error.zig");
pub const log = @import("ziggy").log;
pub const memory_log = @import("ziggy").log.memory_log;
pub const mute_log = @import("ziggy").log.mute_log;
pub const file_log = @import("ziggy").log.file_log;
pub const timestamp_provider = ziggy_utils.timestamp_provider;
pub const errors = ziggy_utils.errors;
pub const console = @import("ziggy").log.console;
pub const format = ziggy_utils.format;
pub const image = @import("lib/image.zig");
pub const reverse_geocode = @import("lib/reverse-geocode.zig");
pub const swallow_error = @import("lib/swallow-error.zig");
pub const retry_or_log = @import("lib/retry-or-log.zig");
pub const try_or_log = @import("lib/try-or-log.zig");
pub const batch_generator = @import("lib/batch-generator.zig");
pub const standard_streams = @import("ziggy").log.standard_streams;
pub const js_string = ziggy_utils.js_string;
pub const js_number = ziggy_utils.js_number;
pub const js_date = @import("lib/js-date.zig");
pub const json = ziggy_utils.json;
pub const hex = @import("lib/hex.zig");
