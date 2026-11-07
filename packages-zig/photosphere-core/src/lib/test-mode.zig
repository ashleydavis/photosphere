//
// What the code that runs differently under test reads from the environment: whether the app was started in test mode
// (PHOTOSPHERE_TEST_MODE is "1") and whether another variable is set to something (set and not empty).
//

const std = @import("std");
const node_utils = @import("node-utils-zig");

//
// The value of an environment variable that is set to something, or null when it is not set or is empty (an empty value counts as
// none).
//
pub fn envValue(name: []const u8) ?[]const u8 {
    const value = node_utils.process_env.getEnv(name) orelse {
        return null;
    };
    if (value.len == 0) {
        return null;
    }
    return value;
}

//
// Whether the app is running in test mode (PHOTOSPHERE_TEST_MODE is "1").
//
pub fn isTestMode() bool {
    const value = node_utils.process_env.getEnv("PHOTOSPHERE_TEST_MODE") orelse {
        return false;
    };
    return std.mem.eql(u8, value, "1");
}
