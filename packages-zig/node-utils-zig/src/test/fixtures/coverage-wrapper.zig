const std = @import("std");
const coverage_options = @import("coverage_options");

//
// Stands in for a program the tests start as a child (the termination child) in a coverage report: it
// replaces itself with kcov running the real program, so the lines the tests reach through the program count too.
// (Only built with -Dcoverage; see docs/zig-test-coverage.md.)
//
pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(allocator);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(allocator, &.{
        coverage_options.kcov_path,
        coverage_options.include_path,
        coverage_options.exclude_path,
        coverage_options.coverage_dir,
        coverage_options.program_path,
    });
    try argv.appendSlice(allocator, arguments[1..]);
    const failure = std.process.replace(init.io, .{
        .argv = argv.items,
    });
    std.debug.print("Failed to run kcov: {s}\n", .{@errorName(failure)});
    return failure;
}
