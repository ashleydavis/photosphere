const std = @import("std");

//
// A stand-in for the system program `psi bug` opens a URL with, for the tests (it is not shipped). On Windows `psi bug`
// starts %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe by full path, so the test copies this program there
// and a real browser is never opened. (Elsewhere the test puts a shell script named xdg-open, or open, on the PATH.)
//
// It writes the arguments it was started with, joined by new lines, to "<its own path>.opened.txt", and calls nothing in
// the CLI. The record is written under another name and renamed into place, so a test waiting for it never reads half
// of it. It is found from the program's own path, not from an environment variable, so it is the same wherever the
// test copies it.
//
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(allocator);

    const ownPath = try std.process.executablePathAlloc(io, allocator);
    const recordPath = try std.fmt.allocPrint(allocator, "{s}.opened.txt", .{ownPath});
    const partialPath = try std.fmt.allocPrint(allocator, "{s}.partial", .{recordPath});
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = partialPath, .data = try std.mem.join(allocator, "\n", arguments[1..]) });
    try cwd.rename(partialPath, cwd, recordPath, io);
}
