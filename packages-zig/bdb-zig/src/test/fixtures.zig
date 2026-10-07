const std = @import("std");

//
// The directory holding the golden fixtures (tests run with the package directory as cwd).
//
pub const FIXTURES_DIR = "bdb-zig/src/test/fixtures";

//
// The directory holding the checked in test databases.
//
pub const TEST_DBS_DIR = "../test/dbs";

//
// Reads a fixture file.
//
pub fn readFixture(allocator: std.mem.Allocator, io: std.Io, name: []const u8) ![]u8 {
    const fixturePath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ FIXTURES_DIR, name });
    return std.Io.Dir.cwd().readFileAlloc(io, fixturePath, allocator, .unlimited);
}

//
// Reads and parses a JSON fixture file.
//
pub fn readJsonFixture(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !std.json.Value {
    const text = try readFixture(allocator, io, name);
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}
