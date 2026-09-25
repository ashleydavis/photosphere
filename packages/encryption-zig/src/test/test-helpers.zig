const std = @import("std");

//
// Helpers shared by the test files (imported by path, so each test binary gets its own copy).
//

//
// Reads a fixture file written by fixtures/generate.ts (tests run with the package directory as cwd).
//
pub fn readFixture(allocator: std.mem.Allocator, fileName: []const u8) ![]u8 {
    const fixturePath = try std.fmt.allocPrint(allocator, "src/test/fixtures/{s}", .{fileName});
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, fixturePath, allocator, .unlimited);
}

//
// Creates the deterministic plaintext used by the fixtures: byte i is (i * 31 + 7) mod 256.
//
pub fn makePlaintext(allocator: std.mem.Allocator, size: usize) ![]u8 {
    const buffer = try allocator.alloc(u8, size);
    for (buffer, 0..) |*byte, index| {
        byte.* = @truncate(index *% 31 +% 7);
    }
    return buffer;
}

//
// Reads everything from a reader into memory.
//
pub fn readAll(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    return reader.allocRemaining(allocator, .unlimited);
}
