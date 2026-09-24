//
// Helpers shared by the tests (not a test file itself).
//

const std = @import("std");

//
// Reads and parses a JSON fixture from src/test/fixtures (the tests run with the package directory as cwd).
//
pub fn loadFixture(allocator: std.mem.Allocator, name: []const u8) !std.json.Value {
    const path = try std.fs.path.join(allocator, &.{ "src/test/fixtures", name });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .unlimited);
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{});
}

//
// Gets a string field of a JSON object.
//
pub fn stringField(value: std.json.Value, name: []const u8) []const u8 {
    return value.object.get(name).?.string;
}

//
// Gets a boolean field of a JSON object.
//
pub fn boolField(value: std.json.Value, name: []const u8) bool {
    return value.object.get(name).?.bool;
}

//
// Gets an integer field of a JSON object.
//
pub fn intField(value: std.json.Value, name: []const u8) i64 {
    return switch (value.object.get(name).?) {
        .integer => |integer| integer,
        .float => |float| @intFromFloat(float),
        else => unreachable,
    };
}

//
// Converts a JSON array of strings to a slice.
//
pub fn stringArray(allocator: std.mem.Allocator, value: std.json.Value) ![]const []const u8 {
    const items = value.array.items;
    const result = try allocator.alloc([]const u8, items.len);
    for (items, 0..) |item, index| {
        result[index] = item.string;
    }
    return result;
}

//
// Creates a unique temporary directory for a test and returns its path.
//
pub fn makeTempDir(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var random_bytes: [8]u8 = undefined;
    std.testing.io.random(&random_bytes);
    const path = try std.fmt.allocPrint(allocator, "/tmp/cli-zig-test-{s}-{x}", .{ name, std.mem.readInt(u64, &random_bytes, .little) });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, path);
    return path;
}

//
// A reader that delivers its input one chunk per read, like a terminal delivers keypresses (and like the
// TypeScript fixture generator writes one key per chunk).
//
pub const ChunkedReader = struct {
    // The reader interface.
    interface: std.Io.Reader,

    // The chunks, in order.
    chunks: []const []const u8,

    // The index of the next chunk.
    next: usize,

    //
    // Creates the reader (it must not move after init).
    //
    pub fn init(self: *ChunkedReader, buffer: []u8, chunks: []const []const u8) void {
        self.* = .{
            .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
            .chunks = chunks,
            .next = 0,
        };
    }

    //
    // Writes the next chunk.
    //
    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        _ = limit;
        const self: *ChunkedReader = @fieldParentPtr("interface", reader);
        if (self.next >= self.chunks.len) {
            return error.EndOfStream;
        }
        const chunk = self.chunks[self.next];
        self.next += 1;
        try writer.writeAll(chunk);
        return chunk.len;
    }
};

//
// Creates a prompt input that delivers the keys one chunk per read.
//
pub fn chunkedInput(allocator: std.mem.Allocator, chunks: []const []const u8) !*@import("cli-zig").prompts.PromptInput {
    const reader = try allocator.create(ChunkedReader);
    reader.init(try allocator.alloc(u8, 4096), chunks);
    const input = try allocator.create(@import("cli-zig").prompts.PromptInput);
    input.* = @import("cli-zig").prompts.PromptInput.init(allocator, &reader.interface, null);
    return input;
}

//
// Splits typed text into one chunk per key (as a terminal delivers them).
//
pub fn splitKeys(allocator: std.mem.Allocator, bytes: []const u8) ![]const []const u8 {
    var chunks: std.ArrayList([]const u8) = .empty;
    var position: usize = 0;
    while (position < bytes.len) {
        const result = (try @import("cli-zig").readline.parseKeypress(allocator, bytes[position..], true)).?;
        try chunks.append(allocator, bytes[position .. position + result.length]);
        position += result.length;
    }
    return chunks.items;
}

//
// Copies a directory tree (`cp -r`).
//
pub fn copyDirectory(allocator: std.mem.Allocator, source: []const u8, dest: []const u8) !void {
    const result = try std.process.run(allocator, std.testing.io, .{ .argv = &.{ "cp", "-r", source, dest } });
    if (result.term != .exited or result.term.exited != 0) {
        return error.CopyFailed;
    }
}

//
// The result of running a CLI.
//
pub const CliResult = struct {
    // The exit code.
    exitCode: u8,

    // What the CLI wrote to stdout.
    stdout: []const u8,

    // What the CLI wrote to stderr.
    stderr: []const u8,
};

//
// Runs a CLI command line (argv[0] is the program) with the environment, from the apps/cli directory.
//
pub fn runCli(allocator: std.mem.Allocator, argv: []const []const u8, environment: *const std.process.Environ.Map) !CliResult {
    const cliDir = try std.Io.Dir.cwd().openDir(std.testing.io, "../cli", .{});
    defer cliDir.close(std.testing.io);
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = argv,
        .cwd = .{ .dir = cliDir },
        .environ_map = environment,
    });
    const exitCode: u8 = switch (result.term) {
        .exited => |code| code,
        else => 255,
    };
    return .{ .exitCode = exitCode, .stdout = result.stdout, .stderr = result.stderr };
}

//
// The test environment of the CLI tests: an isolated config dir, plaintext vault, temp dir and an empty news feed
// (so no network is used), plus PATH and HOME.
//
pub fn cliEnvironment(allocator: std.mem.Allocator, root: []const u8) !*std.process.Environ.Map {
    const map = try allocator.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(allocator);
    const parent = try std.testing.environ.createMap(allocator);
    try map.put("PATH", parent.get("PATH") orelse "/usr/bin:/bin");
    try map.put("HOME", parent.get("HOME") orelse "/root");
    const configDir = try std.fmt.allocPrint(allocator, "{s}/config", .{root});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, configDir);
    try map.put("PHOTOSPHERE_CONFIG_DIR", configDir);
    try map.put("PHOTOSPHERE_VAULT_TYPE", "plaintext");
    try map.put("PHOTOSPHERE_VAULT_DIR", try std.fmt.allocPrint(allocator, "{s}/vault", .{root}));
    const tmpDir = try std.fmt.allocPrint(allocator, "{s}/tmp", .{root});
    try std.Io.Dir.cwd().createDirPath(std.testing.io, tmpDir);
    try map.put("TMPDIR", tmpDir);
    const feed = try std.fmt.allocPrint(allocator, "{s}/news.yaml", .{root});
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = feed, .data = "items: []\n" });
    try map.put("PHOTOSPHERE_NEWS_URL", try std.fmt.allocPrint(allocator, "file://{s}", .{feed}));
    return map;
}
