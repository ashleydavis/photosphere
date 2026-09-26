//
// Two writes to one path, in flight at once (port of src/tests/file-storage-concurrent-write.test.ts).
//
// A write is staged in a temporary file and renamed over the destination. When that temporary file
// was named after the destination alone, both writes used the same one: each opened it, each wrote
// into it, and whichever renamed first took it away from the other. The loser then failed, with
// ENOENT here and with EPERM on Windows, where the file is still open by the other writer. That is
// what stopped `psi add` writing its index into a local encrypted database on Windows, and the
// failure was swallowed, so the command reported "Added 1 files" and the database held none.
//

const std = @import("std");
const storage_zig = @import("storage-zig");
const helpers = @import("test-helpers.zig");

const FileStorage = storage_zig.file_storage.FileStorage;

//
// Large enough that the two writes genuinely overlap rather than each completing within a tick.
//
const WRITE_LENGTH = 2 * 1024 * 1024;

//
// One of the two concurrent writes.
//
const ConcurrentWrite = struct {
    // The storage to write with.
    storage: *FileStorage,

    // The file to write.
    target: []const u8,

    // The bytes to write.
    data: []const u8,

    // True to write with writeStream, false to write with write.
    useStream: bool,

    // The error of the write, if it failed.
    err: ?anyerror = null,

    //
    // Runs the write.
    //
    fn run(self: *ConcurrentWrite) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        if (self.useStream) {
            var input = std.Io.Reader.fixed(self.data);
            self.storage.writeStream(arena.allocator(), std.testing.io, self.target, null, &input, null) catch |err| {
                self.err = err;
            };
        }
        else {
            self.storage.write(arena.allocator(), std.testing.io, self.target, null, self.data) catch |err| {
                self.err = err;
            };
        }
    }
};

//
// Runs two writes of different content to one path at once and checks both completed.
//
fn writeTwiceAtOnce(allocator: std.mem.Allocator, storage: *FileStorage, target: []const u8, useStream: bool) !void {
    const alpha = try allocator.alloc(u8, WRITE_LENGTH);
    @memset(alpha, 'A');
    const beta = try allocator.alloc(u8, WRITE_LENGTH);
    @memset(beta, 'B');
    var writes = [_]ConcurrentWrite{
        .{
            .storage = storage,
            .target = target,
            .data = alpha,
            .useStream = useStream,
        },
        .{
            .storage = storage,
            .target = target,
            .data = beta,
            .useStream = useStream,
        },
    };
    var group: std.Io.Group = .init;
    for (&writes) |*concurrentWrite| {
        try group.concurrent(std.testing.io, ConcurrentWrite.run, .{concurrentWrite});
    }
    try group.await(std.testing.io);
    for (writes) |concurrentWrite| {
        try std.testing.expect(concurrentWrite.err == null);
    }
}

//
// Checks the file holds one writer's content in full: every byte must come from that one write. A mixture
// means the two shared a staging file.
//
fn expectOneWritersContent(allocator: std.mem.Allocator, target: []const u8) !void {
    const written = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, target, allocator, .unlimited);
    try std.testing.expectEqual(@as(usize, WRITE_LENGTH), written.len);
    for (written) |byte| {
        try std.testing.expectEqual(written[0], byte);
    }
}

test "both writes complete and the file holds one writer's content in full" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tempDir = try helpers.makeTempDir(allocator, std.testing.io, "temp-test-concurrent-write");
    defer helpers.removeTempDir(std.testing.io, tempDir);
    var storage = FileStorage.init(tempDir);
    const target = try std.fmt.allocPrint(allocator, "{s}/files.dat", .{tempDir});

    try writeTwiceAtOnce(allocator, &storage, target, false);

    try expectOneWritersContent(allocator, target);
}

test "both stream writes complete and the file holds one writer's content in full" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tempDir = try helpers.makeTempDir(allocator, std.testing.io, "temp-test-concurrent-write");
    defer helpers.removeTempDir(std.testing.io, tempDir);
    var storage = FileStorage.init(tempDir);
    const target = try std.fmt.allocPrint(allocator, "{s}/files.dat", .{tempDir});

    try writeTwiceAtOnce(allocator, &storage, target, true);

    try expectOneWritersContent(allocator, target);
}

test "no staging files are left behind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tempDir = try helpers.makeTempDir(allocator, std.testing.io, "temp-test-concurrent-write");
    defer helpers.removeTempDir(std.testing.io, tempDir);
    var storage = FileStorage.init(tempDir);
    const target = try std.fmt.allocPrint(allocator, "{s}/files.dat", .{tempDir});

    try writeTwiceAtOnce(allocator, &storage, target, false);

    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, tempDir, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    while (try iterator.next(std.testing.io)) |entry| {
        try std.testing.expect(!std.mem.endsWith(u8, entry.name, ".tmp"));
    }
}
