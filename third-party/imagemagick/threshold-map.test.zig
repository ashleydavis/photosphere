const std = @import("std");
const threshold_map = @import("threshold-map.zig");

test "buildThresholdMap makes one string literal of each line and ends the declaration after the last" {
    const header = try threshold_map.buildThresholdMap(std.testing.allocator, "<a>\n  <b/>\n</a>\n");
    defer std.testing.allocator.free(header);
    try std.testing.expectEqualStrings(
        "static const char *const\n  BuiltinMap=\n    \"<a>\\n\"\n    \"  <b/>\\n\"\n    \"</a>\\n\";\n",
        header,
    );
}

test "buildThresholdMap escapes double quotes" {
    const header = try threshold_map.buildThresholdMap(std.testing.allocator, "<?xml version=\"1.0\"?>\n");
    defer std.testing.allocator.free(header);
    try std.testing.expectEqualStrings(
        "static const char *const\n  BuiltinMap=\n    \"<?xml version=\\\"1.0\\\"?>\\n\";\n",
        header,
    );
}

test "buildThresholdMap keeps an empty line as a literal that holds a newline" {
    const header = try threshold_map.buildThresholdMap(std.testing.allocator, "a\n\nb");
    defer std.testing.allocator.free(header);
    try std.testing.expectEqualStrings(
        "static const char *const\n  BuiltinMap=\n    \"a\\n\"\n    \"\\n\"\n    \"b\\n\";\n",
        header,
    );
}

// The declaration is built up in memory, so an allocation that fails part way must free what was built.
test "buildThresholdMap frees what it built when an allocation fails" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, buildForAllocationFailures, .{});
}

//
// Builds a map and frees it, for checkAllAllocationFailures.
//
fn buildForAllocationFailures(allocator: std.mem.Allocator) !void {
    const header = try threshold_map.buildThresholdMap(allocator, "<a>\n  <b c=\"d\"/>\n</a>\n");
    allocator.free(header);
}
