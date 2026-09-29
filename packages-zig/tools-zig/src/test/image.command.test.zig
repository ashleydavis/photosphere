const std = @import("std");
const builtin = @import("builtin");
const tools = @import("tools-zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const Image = tools.Image;

//
// Generates the same ID every time, so the output paths are known.
//
const FixedUuidGenerator = struct {
    //
    // Gets the IUuidGenerator interface.
    //
    fn uuidGenerator(self: *FixedUuidGenerator) utils.uuid_generator.IUuidGenerator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // The functions of the generator.
    const vtable: utils.uuid_generator.IUuidGenerator.VTable = .{ .generate = generate };

    //
    // Returns the fixed ID.
    //
    fn generate(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror![]const u8 {
        _ = ptr;
        _ = allocator;
        _ = io;
        return "fixed";
    }
};

//
// A directory holding fake `magick` and `convert` commands, which write their arguments to a file and write no image.
// It is the only entry of PATH while the test runs, so whichever command Image found, its arguments are recorded.
//
const FakeImageMagickDirectory = struct {
    // Path of the directory, relative to the current directory.
    path: []const u8,

    // The environment passed to the tools (PATH points at the directory).
    environMap: std.process.Environ.Map,

    //
    // Creates the directory with the fake commands and makes PATH point at it.
    //
    fn create(self: *FakeImageMagickDirectory, allocator: std.mem.Allocator, io: std.Io) !void {
        var random_bytes: [8]u8 = undefined;
        io.random(&random_bytes);
        self.path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/fake-magick-{x}", .{std.mem.readInt(u64, &random_bytes, .little)});
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, self.path);
        const absolutePath = try cwd.realPathFileAlloc(io, self.path, allocator);
        const argumentsPath = try std.fmt.allocPrint(allocator, "{s}/arguments.txt", .{absolutePath});
        for ([_][]const u8{ "magick", "convert" }) |name| {
            if (builtin.os.tag == .windows) {
                try cwd.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(allocator, "{s}/{s}.cmd", .{ self.path, name }), .data = try std.fmt.allocPrint(allocator, "@echo %*> \"{s}\"\r\n", .{argumentsPath}) });
            }
            else {
                const scriptPath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.path, name });
                try cwd.writeFile(io, .{ .sub_path = scriptPath, .data = try std.fmt.allocPrint(allocator, "#!/bin/sh\nprintf '%s\\n' \"$*\" > '{s}'\n", .{argumentsPath}) });
                _ = try node_utils.exec.exec(allocator, io, try std.fmt.allocPrint(allocator, "chmod +x {s}", .{scriptPath}));
            }
        }
        self.environMap = std.process.Environ.Map.init(allocator);
        try self.environMap.put("PATH", absolutePath);
        node_utils.process_env.setEnvironMap(&self.environMap);
    }

    //
    // Reads the arguments the last fake command was run with.
    //
    fn arguments(self: *FakeImageMagickDirectory, allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
        const text = try std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(allocator, "{s}/arguments.txt", .{self.path}), allocator, .unlimited);
        return std.mem.trimEnd(u8, text, " \r\n");
    }

    //
    // Restores the environment and deletes the directory.
    //
    fn destroy(self: *FakeImageMagickDirectory, io: std.Io) void {
        node_utils.process_env.setEnvironMap(null);
        std.Io.Dir.cwd().deleteTree(io, self.path) catch {};
    }
};

test "resize and transform write their numbers as a template string writes a number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var directory: FakeImageMagickDirectory = undefined;
    try directory.create(allocator, io);
    defer directory.destroy(io);
    // The failed validation logs the command and its output; the test process's stdout belongs to the test runner.
    var capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&capture.writer, &capture.writer);
    defer utils.console.setCapture(null, null);
    var uuids: FixedUuidGenerator = .{};
    var image = Image.init("build.zig");

    try std.testing.expectError(error.Thrown, image.resize(allocator, io, .{ .width = 1e21, .height = 0, .quality = 1e-7, .format = null, .ext = "jpg" }, "out", uuids.uuidGenerator()));
    try std.testing.expectEqualStrings("build.zig -resize 1e+21x -strip -quality 1e-7 out/temp_resize_fixed.jpg", try directory.arguments(allocator, io));

    try std.testing.expectError(error.Thrown, image.transform(allocator, io, .{ .rotate = 1e21 }, "out", uuids.uuidGenerator()));
    try std.testing.expectEqualStrings("build.zig -rotate 1e+21 out/temp_transform_output_fixed.jpg", try directory.arguments(allocator, io));
}
