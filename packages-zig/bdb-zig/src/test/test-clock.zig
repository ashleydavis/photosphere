const utils = @import("utils-zig");

//
// A timestamp provider for tests (the real clock; bdb only passes it through).
//
pub var timestamp_provider: utils.timestamp_provider.TimestampProvider = .{};
