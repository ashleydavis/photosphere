//
// The query of the example page's address.
//

const std = @import("std");
const ziggy = @import("ziggy-core");

//
// Says whether the test mode switch is on, which is all the example's page reads from its address.
//
pub fn pageQuery(core: *ziggy.core.Core, allocator: std.mem.Allocator, test_mode: bool) anyerror![]const u8 {
    _ = core;
    if (test_mode) {
        return try allocator.dupe(u8, "testMode=1");
    }
    return try allocator.dupe(u8, "");
}
