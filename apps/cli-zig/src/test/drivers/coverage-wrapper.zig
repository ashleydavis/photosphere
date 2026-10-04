const std = @import("std");
const coverage_options = @import("coverage_options");

//
// Stands in for a program the unit tests run (psi) in the second pass of a coverage report: it replaces itself with
// kcov running the real program, so the lines the tests reach through the program count too. A program started by a
// program kcov is already tracing cannot be traced by a kcov of its own, so it is run as it is. (Only built with
// -Dcoverage; see docs/zig-test-coverage.md.)
//
pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(allocator);
    var argv: std.ArrayList([]const u8) = .empty;
    if (!try isTraced(allocator, init.io)) {
        try argv.appendSlice(allocator, &.{
            coverage_options.kcov_path,
            coverage_options.include_path,
            coverage_options.exclude_path,
            coverage_options.coverage_dir,
        });
    }
    try argv.append(allocator, coverage_options.program_path);
    try argv.appendSlice(allocator, arguments[1..]);
    const failure = std.process.replace(init.io, .{
        .argv = argv.items,
    });
    std.debug.print("Failed to run {s}: {s}\n", .{ argv.items[0], @errorName(failure) });
    return failure;
}

//
// Whether this process is being traced (by the kcov of the program that started it): the TracerPid of
// /proc/self/status is not 0.
//
fn isTraced(allocator: std.mem.Allocator, io: std.Io) !bool {
    const file = try std.Io.Dir.cwd().openFile(io, "/proc/self/status", .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    const status = try reader.interface.allocRemaining(allocator, .unlimited);
    var lines = std.mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "TracerPid:")) {
            return !std.mem.eql(u8, std.mem.trim(u8, line["TracerPid:".len..], " \t"), "0");
        }
    }
    return false;
}
