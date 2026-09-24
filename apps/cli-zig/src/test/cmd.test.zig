const std = @import("std");
const cli = @import("cli-zig");

test "the replicate and verify options default to undefined" {
    const replicateOptions: cli.replicate.IReplicateCommandOptions = .{};
    try std.testing.expect(replicateOptions.dest == null);
    try std.testing.expect(replicateOptions.base.db == null);
    const verifyOptions: cli.verify.IVerifyCommandOptions = .{};
    try std.testing.expect(verifyOptions.full == null);
    try std.testing.expect(verifyOptions.base.yes == null);
}
