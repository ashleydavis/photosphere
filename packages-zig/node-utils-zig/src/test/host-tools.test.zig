const std = @import("std");
const node_utils = @import("node-utils-zig");
const utils = @import("utils-zig");

const exec = node_utils.exec.exec;
const host_tools = node_utils.host_tools;

// What the fake host was last asked and what it answers.
const FakeHost = struct {
    // The method of the last request.
    method: [64]u8 = undefined,
    method_length: usize = 0,

    // The JSON text of the last request.
    request: [1024]u8 = undefined,
    request_length: usize = 0,

    // The answer, and whether the host fails with it as its reason.
    answer: []const u8,
    fails: bool,

    fn requester(self: *FakeHost) utils.host_requester.IHostRequester {
        return .{
            .ptr = self,
            .request = handle,
        };
    }

    fn handle(ptr: *anyopaque, allocator: std.mem.Allocator, method: []const u8, request_json: []const u8) anyerror![]const u8 {
        const self: *FakeHost = @ptrCast(@alignCast(ptr));
        @memcpy(self.method[0..method.len], method);
        self.method_length = method.len;
        @memcpy(self.request[0..request_json.len], request_json);
        self.request_length = request_json.len;
        if (self.fails) {
            return utils.errors.throwError("{s} failed: {s}", .{ method, self.answer });
        }
        return try allocator.dupe(u8, self.answer);
    }
};

test "a magick command is asked of the host as runMagick with its arguments and returns the output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host: FakeHost = .{
        .answer = "{\"exitCode\":0,\"output\":\"800 600\"}",
        .fails = false,
    };
    var storage: host_tools.HostToolRunner = undefined;
    const tools = host_tools.hostToolRunner(host.requester(), &storage);

    const result = try exec(arena.allocator(), std.testing.io, tools, "magick identify -format \"%w %h\" \"/data/a b.jpg\"");
    try std.testing.expectEqualStrings("800 600", result.stdout);
    try std.testing.expectEqualStrings("runMagick", host.method[0..host.method_length]);
    try std.testing.expectEqualStrings("{\"args\":[\"identify\",\"-format\",\"%w %h\",\"/data/a b.jpg\"]}", host.request[0..host.request_length]);
}

test "ffprobe and ffmpeg commands are asked of the host as runFfprobe and runFfmpeg" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host: FakeHost = .{
        .answer = "{\"exitCode\":0,\"output\":\"{}\"}",
        .fails = false,
    };
    var storage: host_tools.HostToolRunner = undefined;
    const tools = host_tools.hostToolRunner(host.requester(), &storage);

    _ = try exec(arena.allocator(), std.testing.io, tools, "ffprobe -version");
    try std.testing.expectEqualStrings("runFfprobe", host.method[0..host.method_length]);
    _ = try exec(arena.allocator(), std.testing.io, tools, "ffmpeg -version");
    try std.testing.expectEqualStrings("runFfmpeg", host.method[0..host.method_length]);
}

test "a tool that exits non-zero fails the command with its output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host: FakeHost = .{
        .answer = "{\"exitCode\":1,\"output\":\"unable to open image\"}",
        .fails = false,
    };
    var storage: host_tools.HostToolRunner = undefined;
    const tools = host_tools.hostToolRunner(host.requester(), &storage);

    try std.testing.expectError(error.Thrown, exec(arena.allocator(), std.testing.io, tools, "magick \"x.jpg\" -resize 10x10 \"y.jpg\""));
}

test "a host that cannot run the tool fails the command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host: FakeHost = .{
        .answer = "ImageMagick is not linked",
        .fails = true,
    };
    var storage: host_tools.HostToolRunner = undefined;
    const tools = host_tools.hostToolRunner(host.requester(), &storage);

    try std.testing.expectError(error.Thrown, exec(arena.allocator(), std.testing.io, tools, "magick -version"));
}

test "readReply fails on an answer without an exit code or output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Thrown, host_tools.readReply(arena.allocator(), "runMagick", "{\"output\":\"x\"}"));
    try std.testing.expectError(error.Thrown, host_tools.readReply(arena.allocator(), "runMagick", "{\"exitCode\":0}"));
    try std.testing.expectError(error.Thrown, host_tools.readReply(arena.allocator(), "runMagick", "not json"));
}

test "toolRunnerFor gives no runner on a platform that starts the programs" {
    var host: FakeHost = .{
        .answer = "{}",
        .fails = false,
    };
    var storage: host_tools.HostToolRunner = undefined;
    try std.testing.expect(try host_tools.toolRunnerFor(host.requester(), &storage) == null);
    try std.testing.expect(try host_tools.toolRunnerFor(null, &storage) == null);
}
