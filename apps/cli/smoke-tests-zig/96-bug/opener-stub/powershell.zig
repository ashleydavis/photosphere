const std = @import("std");

//
// Stands in for Windows PowerShell, the Windows URL opener, while the bug test runs, so no browser starts. The test
// builds it at test time as <SYSTEMROOT>\System32\WindowsPowerShell\v1.0\powershell.exe under a SYSTEMROOT of its
// own, the path at which `psi bug` looks for PowerShell. It writes the arguments it was started with, one per line,
// to BUG_OPENER_CAPTURE_FILE, through a temporary file renamed into place so the test never reads half of them.
//
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const capturePath = init.environ_map.get("BUG_OPENER_CAPTURE_FILE") orelse {
        std.debug.print("BUG_OPENER_CAPTURE_FILE is not set, so there is nowhere to record the arguments\n", .{});
        std.process.exit(1);
    };
    const arguments = try init.minimal.args.toSlice(allocator);
    const recorded = try std.mem.join(allocator, "\n", arguments[1..]);
    const partialPath = try std.fmt.allocPrint(allocator, "{s}.partial", .{capturePath});
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = partialPath, .data = recorded });
    try cwd.rename(partialPath, cwd, capturePath, io);
}
