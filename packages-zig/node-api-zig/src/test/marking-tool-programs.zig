const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const builtin = @import("builtin");
const node_utils = @import("node-utils-zig");
const test_files = @import("test-files.zig");

//
// A directory of `magick`, `ffmpeg` and `ffprobe` programs that each leave a marker file behind when they are started, made
// the only entry of PATH while a test runs. A test that must start no program for those tools checks afterwards that no marker
// was left, so a command that went to an installed program instead of the tools built in would be seen.
//
pub const MarkingToolPrograms = struct {
    // Absolute path of the directory holding the programs.
    path: []const u8,

    // Absolute path of the marker file a program writes when it is started.
    markerPath: []const u8,

    // The environment the test program had before, put back when this is destroyed.
    previousMap: *const std.process.Environ.Map,

    // The environment the programs are found through: the one the test program had, with PATH holding only the directory.
    environMap: std.process.Environ.Map,

    //
    // Writes the programs into a new directory under tempDir and makes PATH hold only that directory.
    //
    pub fn create(self: *MarkingToolPrograms, allocator: std.mem.Allocator, io: std.Io, log: ILog, tempDir: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        self.path = try std.fs.path.join(allocator, &.{ tempDir, "marking-tool-programs" });
        try cwd.createDirPath(io, self.path);
        self.markerPath = try std.fs.path.join(allocator, &.{ self.path, "started" });
        for ([_][]const u8{ "magick", "ffmpeg", "ffprobe" }) |name| {
            // cmd.exe finds `<name>.cmd` on PATH and needs no executable bit.
            if (builtin.os.tag == .windows) {
                const scriptPath = try std.fs.path.join(allocator, &.{ self.path, try std.mem.concat(allocator, u8, &.{ name, ".cmd" }) });
                try cwd.writeFile(io, .{
                    .sub_path = scriptPath,
                    .data = try std.fmt.allocPrint(allocator, "@type nul > \"{s}\"\r\n", .{self.markerPath}),
                });
            }
            else {
                const scriptPath = try std.fs.path.join(allocator, &.{ self.path, name });
                try cwd.writeFile(io, .{
                    .sub_path = scriptPath,
                    .data = try std.fmt.allocPrint(allocator, "#!/bin/sh\n: > '{s}'\n", .{self.markerPath}),
                });
                _ = try node_utils.exec.exec(allocator, io, log, null, try std.fmt.allocPrint(allocator, "chmod +x \"{s}\"", .{scriptPath}));
            }
        }
        // The rest of the environment the test runs in is kept, so the scratch space and the rest stay the test program's own.
        const current = node_utils.process_env.getEnvironMap() orelse {
            std.debug.print("The test environment is not set up: call test_environment.setupEnvironment first.\n", .{});
            return error.TestUnexpectedResult;
        };
        self.previousMap = current;
        self.environMap = try current.clone(allocator);
        try self.environMap.put("PATH", self.path);
        node_utils.process_env.setEnvironMap(&self.environMap);
    }

    //
    // Whether any of the programs has been started.
    //
    pub fn anyStarted(self: *MarkingToolPrograms, io: std.Io) bool {
        return test_files.fileExists(io, self.markerPath);
    }

    //
    // Puts back the environment the test program had. The directory goes with the test's own temporary directory.
    //
    pub fn destroy(self: *MarkingToolPrograms) void {
        node_utils.process_env.setEnvironMap(self.previousMap);
    }
};
