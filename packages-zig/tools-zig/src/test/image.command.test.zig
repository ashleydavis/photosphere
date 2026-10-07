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
        tools.Image.resetInitialization();
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

        // Image detects the installation once and remembers the commands it found, so the fake tools would otherwise
        // be the ones every later test runs against the real PATH, and where only the legacy `convert` and
        // `identify` are installed that is a `magick` command nothing can run. This is what
        // tool-verification.test.zig's FakeToolsDirectory does.
        tools.Image.resetInitialization();
        std.Io.Dir.cwd().deleteTree(io, self.path) catch {};
    }
};

//
// A directory holding fake ImageMagick commands that print the same text whatever they are asked, and that can be
// made to fail from the second call on. It is the only entry of PATH while the test runs, so every command the
// ImageMagick code runs is the fake one.
//
const FakeOutputTools = struct {
    // Path of the directory, relative to the current directory.
    path: []const u8,

    // The environment passed to the tools (PATH points at the directory).
    environMap: std.process.Environ.Map,

    //
    // Creates the directory with a fake command of each of the given names, each printing `output`, and makes PATH
    // point at it. With `failAfterFirstCall` set, a command answers the first call and exits non-zero from the
    // second on, which is what a tool that works when it is found and then stops working does.
    //
    fn create(self: *FakeOutputTools, allocator: std.mem.Allocator, io: std.Io, names: []const []const u8, output: []const u8, failAfterFirstCall: bool) !void {
        var random_bytes: [8]u8 = undefined;
        io.random(&random_bytes);
        self.path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/fake-magick-output-{x}", .{std.mem.readInt(u64, &random_bytes, .little)});
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, self.path);
        const absolutePath = try cwd.realPathFileAlloc(io, self.path, allocator);
        for (names) |name| {
            // The marker that remembers the command has been run, so the second call can tell it from the first.
            const markerPath = try std.fmt.allocPrint(allocator, "{s}/called-{s}", .{ absolutePath, name });
            const subPath = if (builtin.os.tag == .windows)
                try std.fmt.allocPrint(allocator, "{s}/{s}.cmd", .{ self.path, name })
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.path, name });
            if (builtin.os.tag == .windows) {
                // `echo(` is what prints an empty line in cmd.exe, where a bare `echo` with no text after it prints
                // "ECHO is off." instead. The marker is checked with `if exist` on a line of its own, so `exit /b 1`
                // ends the script whichever way cmd.exe reads the block.
                const script = if (failAfterFirstCall)
                    try std.fmt.allocPrint(allocator, "@echo off\r\n@if exist \"{s}\" exit /b 1\r\n@type nul > \"{s}\"\r\n@echo({s}\r\n", .{ markerPath, markerPath, output })
                else
                    try std.fmt.allocPrint(allocator, "@echo off\r\n@echo({s}\r\n", .{output});
                try cwd.writeFile(io, .{ .sub_path = subPath, .data = script });
            }
            else {
                const script = if (failAfterFirstCall)
                    try std.fmt.allocPrint(allocator, "#!/bin/sh\nif [ -e '{s}' ]; then exit 1; fi\n: > '{s}'\nprintf '%s\\n' '{s}'\n", .{ markerPath, markerPath, output })
                else
                    try std.fmt.allocPrint(allocator, "#!/bin/sh\nprintf '%s\\n' '{s}'\n", .{output});
                try cwd.writeFile(io, .{ .sub_path = subPath, .data = script });
                _ = try node_utils.exec.exec(allocator, io, try std.fmt.allocPrint(allocator, "chmod +x {s}", .{subPath}));
            }
        }
        self.environMap = std.process.Environ.Map.init(allocator);
        try self.environMap.put("PATH", absolutePath);
        node_utils.process_env.setEnvironMap(&self.environMap);
        tools.Image.resetInitialization();
    }

    //
    // Restores the environment and deletes the directory.
    //
    fn destroy(self: *FakeOutputTools, io: std.Io) void {
        node_utils.process_env.setEnvironMap(null);
        tools.Image.resetInitialization();
        std.Io.Dir.cwd().deleteTree(io, self.path) catch {};
    }
};

//
// The commands of a modern ImageMagick installation.
//
const modern_command_names = [_][]const u8{ "magick" };

//
// The commands of a legacy ImageMagick installation.
//
const legacy_command_names = [_][]const u8{ "convert", "identify" };

//
// Expects getDominantColor to refuse what the fake commands print, as the TypeScript does with a value that is not
// three numbers between 0 and 255.
//
fn expectDominantColorRefusal(allocator: std.mem.Allocator, io: std.Io, fakeOutput: []const u8) !void {
    var directory: FakeOutputTools = undefined;
    try directory.create(allocator, io, &modern_command_names, fakeOutput, false);
    defer directory.destroy(io);
    var image = Image.init("../test/test.png");
    try std.testing.expectError(error.Thrown, image.getDominantColor(allocator, io));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "Failed to extract dominant color: Error: Invalid RGB values: {s}", .{fakeOutput}), utils.errors.lastErrorMessage());
}

test "getInfo reads a width and a height of NaN from output ImageMagick did not write" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var directory: FakeOutputTools = undefined;

    // The fake identify prints "100" with no height, so parseInt reads the width and finds nothing for the height.
    try directory.create(allocator, io, &modern_command_names, "100", false);
    defer directory.destroy(io);
    var image = Image.init("../test/test.png");
    const info = try image.getInfo(allocator, io);
    try std.testing.expectEqual(tools.image.ImageMagickType.modern, tools.Image.getImageMagickType());
    try std.testing.expectEqual(@as(f64, 100), info.dimensions.width);
    try std.testing.expect(std.math.isNan(info.dimensions.height));

    // Output with no width at all is NaN for both.
    directory.destroy(io);
    try directory.create(allocator, io, &modern_command_names, "", false);
    var blank = Image.init("../test/test.png");
    const blankInfo = try blank.getInfo(allocator, io);
    try std.testing.expect(std.math.isNan(blankInfo.dimensions.width));
    try std.testing.expect(std.math.isNan(blankInfo.dimensions.height));
    try std.testing.expect(blankInfo.createdAt == null);
}

test "getDominantColor refuses output that is not three values between 0 and 255" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    // Two values where three are needed.
    try expectDominantColorRefusal(allocator, io, "1,2");

    // A value past 255.
    try expectDominantColorRefusal(allocator, io, "256,0,0");

    // A value that is not a number at all.
    try expectDominantColorRefusal(allocator, io, "a,b,c");
}

test "verifyImageMagick reports the magick command failing after the installation was found" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var directory: FakeOutputTools = undefined;

    // The fake magick answers the `magick -version` that finds the installation and fails the one
    // verifyImageMagick runs next.
    try directory.create(allocator, io, &modern_command_names, "Version: ImageMagick 7.1.1-29", true);
    defer directory.destroy(io);

    const status = try tools.Image.verifyImageMagick(allocator, io);

    try std.testing.expect(!status.available);
    try std.testing.expectEqualStrings("Modern ImageMagick 'magick' command failed: Error: Command failed: magick -version\n", status.@"error".?);
    try std.testing.expect(status.version == null);
    try std.testing.expect(status.@"type" == null);

    // The installation is still the one that was detected, so the next call runs the command again.
    try std.testing.expectEqual(tools.image.ImageMagickType.modern, tools.Image.getImageMagickType());
}

test "verifyImageMagick reports the convert command failing after the installation was found" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var directory: FakeOutputTools = undefined;

    // Both legacy commands answer the calls that find the installation, and convert fails the one
    // verifyImageMagick runs next.
    try directory.create(allocator, io, &legacy_command_names, "Version: ImageMagick 6.9.11-60", true);
    defer directory.destroy(io);

    const status = try tools.Image.verifyImageMagick(allocator, io);

    try std.testing.expect(!status.available);
    try std.testing.expectEqualStrings("Legacy ImageMagick 'convert' command failed: Error: Command failed: convert -version\n", status.@"error".?);
    try std.testing.expect(status.version == null);
    try std.testing.expect(status.@"type" == null);
    try std.testing.expectEqual(tools.image.ImageMagickType.legacy, tools.Image.getImageMagickType());
}

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
    var image = Image.init("../test/test.png");

    // The command quotes both paths, as the TypeScript does (`magick "<file>" -resize <geometry> -strip "<output>"`),
    // and the output path is joined with node-utils' path.join, the port of Node's path.join, which normalizes
    // every `/` to a `\` on Windows. /bin/sh takes the quotes apart before the fake command sees the arguments, and
    // cmd.exe hands the command line to the fake .cmd exactly as it is, so on Windows the quotes and every space the
    // template string leaves are recorded too. transform adds one of those spaces: the TypeScript's transformCommand
    // starts with a space (` -rotate 1e+21`) and the template puts another one in front of it, which /bin/sh eats as
    // an argument separator and cmd.exe does not.
    const resizeArguments = if (builtin.os.tag == .windows)
        "\"../test/test.png\" -resize 1e+21x -strip -quality 1e-7 \"out\\temp_resize_fixed.jpg\""
    else
        "../test/test.png -resize 1e+21x -strip -quality 1e-7 out/temp_resize_fixed.jpg";
    const transformArguments = if (builtin.os.tag == .windows)
        "\"../test/test.png\"  -rotate 1e+21 \"out\\temp_transform_output_fixed.jpg\""
    else
        "../test/test.png -rotate 1e+21 out/temp_transform_output_fixed.jpg";

    try std.testing.expectError(error.Thrown, image.resize(allocator, io, .{ .width = 1e21, .height = 0, .quality = 1e-7, .format = null, .ext = "jpg" }, "out", uuids.uuidGenerator()));
    try std.testing.expectEqualStrings(resizeArguments, try directory.arguments(allocator, io));

    try std.testing.expectError(error.Thrown, image.transform(allocator, io, .{ .rotate = 1e21 }, "out", uuids.uuidGenerator()));
    try std.testing.expectEqualStrings(transformArguments, try directory.arguments(allocator, io));
}
