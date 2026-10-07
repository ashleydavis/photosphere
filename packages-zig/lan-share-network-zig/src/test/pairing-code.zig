const std = @import("std");

//
// Draws a random pairing code (1000-9999) for one test.
//
// LAN share discovery is machine-wide: every receiver on this host broadcasts on the same UDP port and a sender
// pairs with whichever one announces a matching code. A fixed code would let a test pair with the receiver of
// another copy of the same test, run from another worktree at the same moment, so each test draws its own.
//
pub fn pairingCode() ![]const u8 {
    var bytes: [4]u8 = undefined;
    std.testing.io.random(&bytes);
    const code = 1000 + std.mem.readInt(u32, &bytes, .little) % 9000;
    return std.fmt.allocPrint(std.heap.smp_allocator, "{d}", .{code});
}

//
// Draws a random pairing code different from another one.
//
pub fn otherPairingCode(code: []const u8) ![]const u8 {
    while (true) {
        const other = try pairingCode();
        if (!std.mem.eql(u8, other, code)) {
            return other;
        }
    }
}
