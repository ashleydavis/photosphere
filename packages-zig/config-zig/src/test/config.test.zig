const std = @import("std");
const config = @import("config-zig");

test "the version and the build metadata are set" {
    try std.testing.expect(config.version.len > 0);
    try std.testing.expect(config.buildMetadata.commitHash.len > 0);
    try std.testing.expect(config.buildMetadata.buildDate.len > 0);
}
