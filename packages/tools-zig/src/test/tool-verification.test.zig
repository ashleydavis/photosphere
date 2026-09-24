const std = @import("std");
const tools = @import("tools-zig");
const node_utils = @import("node-utils-zig");

//
// A fake tool: a shell script with the given name that prints the given output.
//
const FakeTool = struct {
    // The command name.
    name: []const u8,

    // What the command prints to stdout.
    output: []const u8,
};

//
// A directory of fake tools that is the only entry of PATH while the test runs.
//
const FakeToolsDirectory = struct {
    // Path of the directory holding the fake tools.
    path: []const u8,

    // The environment passed to the tools (PATH points at `path`).
    environMap: std.process.Environ.Map,

    //
    // Creates the directory, writes the fake tools and makes PATH point at it.
    //
    fn create(self: *FakeToolsDirectory, allocator: std.mem.Allocator, io: std.Io, fakeTools: []const FakeTool) !void {
        var random_bytes: [8]u8 = undefined;
        io.random(&random_bytes);
        self.path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/fake-tools-{x}", .{std.mem.readInt(u64, &random_bytes, .little)});
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, self.path);
        for (fakeTools) |fakeTool| {
            const scriptPath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.path, fakeTool.name });
            const script = try std.fmt.allocPrint(allocator, "#!/bin/sh\nprintf '%s\\n' '{s}'\n", .{fakeTool.output});
            try cwd.writeFile(io, .{ .sub_path = scriptPath, .data = script });
            _ = try node_utils.exec.exec(allocator, io, try std.fmt.allocPrint(allocator, "chmod +x {s}", .{scriptPath}));
        }
        const absolutePath = try cwd.realPathFileAlloc(io, self.path, allocator);
        self.environMap = std.process.Environ.Map.init(allocator);
        try self.environMap.put("PATH", absolutePath);
        node_utils.process_env.setEnvironMap(&self.environMap);
        tools.Image.resetInitialization();
    }

    //
    // Restores the environment and deletes the directory.
    //
    fn destroy(self: *FakeToolsDirectory, io: std.Io) void {
        node_utils.process_env.setEnvironMap(null);
        tools.Image.resetInitialization();
        std.Io.Dir.cwd().deleteTree(io, self.path) catch {};
    }
};

test "verifyTools reports every tool with its version when modern ImageMagick, ffprobe and ffmpeg are installed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var directory: FakeToolsDirectory = undefined;
    try directory.create(allocator, io, &.{
        .{ .name = "magick", .output = "Version: ImageMagick 7.1.1-29 Q16-HDRI x86_64 https://imagemagick.org" },
        .{ .name = "ffprobe", .output = "ffprobe version 6.1.1-3ubuntu5 Copyright (c) 2007-2023 the FFmpeg developers" },
        .{ .name = "ffmpeg", .output = "ffmpeg version n7.0 Copyright (c) 2000-2024 the FFmpeg developers" },
    });
    defer directory.destroy(io);

    const status = try tools.verifyTools(allocator, io);

    try std.testing.expect(status.allAvailable);
    try std.testing.expectEqual(@as(usize, 0), status.missingTools.len);
    try std.testing.expectEqualStrings("7.1.1-29", status.magick.version.?);
    try std.testing.expectEqualStrings("6.1.1-3ubuntu5", status.ffprobe.version.?);
    try std.testing.expectEqualStrings("n7.0", status.ffmpeg.version.?);
}

test "verifyImageMagick falls back to legacy convert/identify" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var directory: FakeToolsDirectory = undefined;
    try directory.create(allocator, io, &.{
        .{ .name = "convert", .output = "Version: ImageMagick 6.9.11-60 Q16 x86_64 2021-01-25" },
        .{ .name = "identify", .output = "Version: ImageMagick 6.9.11-60 Q16 x86_64 2021-01-25" },
    });
    defer directory.destroy(io);

    const status = try tools.Image.verifyImageMagick(allocator, io);

    try std.testing.expect(status.available);
    try std.testing.expectEqualStrings("6.9.11-60", status.version.?);
    try std.testing.expectEqual(tools.image.ImageMagickType.legacy, status.@"type".?);
}

test "verifyImageMagick reports unknown when the version cannot be found" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var directory: FakeToolsDirectory = undefined;
    try directory.create(allocator, io, &.{
        .{ .name = "magick", .output = "Something else" },
    });
    defer directory.destroy(io);

    const status = try tools.Image.verifyImageMagick(allocator, io);

    try std.testing.expect(status.available);
    try std.testing.expectEqualStrings("unknown", status.version.?);
    try std.testing.expectEqual(tools.image.ImageMagickType.modern, status.@"type".?);
}

test "verifyImageMagick needs both convert and identify for a legacy installation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var directory: FakeToolsDirectory = undefined;
    try directory.create(allocator, io, &.{
        .{ .name = "convert", .output = "Version: ImageMagick 6.9.11-60" },
    });
    defer directory.destroy(io);

    const status = try tools.Image.verifyImageMagick(allocator, io);

    try std.testing.expect(!status.available);
    try std.testing.expectEqualStrings("ImageMagick not found. Please install ImageMagick and ensure either 'magick' or 'convert'/'identify' commands are available.", status.@"error".?);
}

test "verifyTools lists every missing tool when nothing is installed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var directory: FakeToolsDirectory = undefined;
    try directory.create(allocator, io, &.{});
    defer directory.destroy(io);

    const status = try tools.verifyTools(allocator, io);

    try std.testing.expect(!status.allAvailable);
    try std.testing.expectEqual(@as(usize, 3), status.missingTools.len);
    try std.testing.expectEqualStrings("ImageMagick", status.missingTools[0]);
    try std.testing.expectEqualStrings("ffprobe", status.missingTools[1]);
    try std.testing.expectEqualStrings("ffmpeg", status.missingTools[2]);
    try std.testing.expectEqualStrings("ImageMagick not found. Please install ImageMagick and ensure either 'magick' or 'convert'/'identify' commands are available.", status.magick.@"error".?);
    try std.testing.expectEqualStrings("ffprobe not found. Make sure ffmpeg is installed.", status.ffprobe.@"error".?);
    try std.testing.expectEqualStrings("ffmpeg not found. Make sure ffmpeg is installed.", status.ffmpeg.@"error".?);
}

test "verifyTools lists only the missing tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var directory: FakeToolsDirectory = undefined;
    try directory.create(allocator, io, &.{
        .{ .name = "magick", .output = "Version: ImageMagick 7.1.1-29" },
        .{ .name = "ffmpeg", .output = "ffmpeg version 7.0" },
    });
    defer directory.destroy(io);

    const status = try tools.verifyTools(allocator, io);

    try std.testing.expect(!status.allAvailable);
    try std.testing.expectEqual(@as(usize, 1), status.missingTools.len);
    try std.testing.expectEqualStrings("ffprobe", status.missingTools[0]);
    try std.testing.expect(status.magick.available);
    try std.testing.expect(status.ffmpeg.available);
}
