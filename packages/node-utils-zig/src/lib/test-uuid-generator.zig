const std = @import("std");
const utils = @import("utils-zig");
const uuid_generator = utils.uuid_generator;
const process_env = @import("process-env.zig");

//
// Equivalent of `parseInt(text, 10) || 0`: parses the leading decimal digits (with an optional sign),
// returning 0 when there are none.
//
fn parseIntOrZero(text: []const u8) i64 {
    var index: usize = 0;
    var negative = false;
    if (index < text.len and (text[index] == '+' or text[index] == '-')) {
        negative = text[index] == '-';
        index += 1;
    }
    var value: i64 = 0;
    while (index < text.len and std.ascii.isDigit(text[index])) {
        value = value *| 10 +| @as(i64, text[index] - '0');
        index += 1;
    }
    return if (negative) -value else value;
}

//
// Test UUID generator that creates deterministic UUIDs with good shard distribution.
// Uses a file-backed counter with an exclusive-create lock so concurrent processes
// each receive a unique counter value without collisions.
//
pub const TestUuidGenerator = struct {
    // Path of the file that holds the last counter value.
    counterFilePath: []const u8,

    // Path of the lock file that guards the counter file.
    lockFilePath: []const u8,

    //
    // Creates the generator. The counter file lives in TEST_TMP_DIR (or ./test/tmp).
    //
    pub fn init(allocator: std.mem.Allocator) !TestUuidGenerator {
        const testTmpDir = blk: {
            if (process_env.getEnv("TEST_TMP_DIR")) |value| {
                if (value.len > 0) {
                    break :blk value;
                }
            }
            break :blk "./test/tmp";
        };
        const counterFilePath = try std.fs.path.join(allocator, &.{ testTmpDir, "photosphere-test-uuid-counter" });
        return .{
            .counterFilePath = counterFilePath,
            .lockFilePath = try std.fmt.allocPrint(allocator, "{s}.lock", .{counterFilePath}),
        };
    }

    //
    // Gets the IUuidGenerator interface for this generator.
    //
    pub fn uuidGenerator(self: *TestUuidGenerator) uuid_generator.IUuidGenerator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    //
    // The IUuidGenerator functions of this generator.
    //
    const vtable: uuid_generator.IUuidGenerator.VTable = .{
        .generate = generateErased,
    };

    //
    // Increments the file-backed counter and returns the UUID for the new value.
    //
    pub fn generate(self: *TestUuidGenerator, allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
        try self.acquireLock(io);
        defer self.releaseLock(io);

        const cwd = std.Io.Dir.cwd();
        var counter: i64 = 0;
        if (cwd.readFileAlloc(io, self.counterFilePath, allocator, .unlimited)) |data| {
            counter = parseIntOrZero(std.mem.trim(u8, data, " \t\r\n"));
        }
        else |err| {
            if (err != error.FileNotFound) {
                return err;
            }
        }
        counter += 1;
        const counterText = try std.fmt.allocPrint(allocator, "{d}", .{counter});
        try cwd.writeFile(io, .{ .sub_path = self.counterFilePath, .data = counterText });
        return generateDeterministicUuid(allocator, counter);
    }

    //
    // Acquires a spinlock via O_CREAT|O_EXCL so only one process increments the counter
    // at a time. Removes a stale lock after 5 seconds of waiting.
    //
    fn acquireLock(self: *TestUuidGenerator, io: std.Io) !void {
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, std.fs.path.dirname(self.lockFilePath) orelse ".");
        const maxWaitMs: i64 = 5000;
        const startTime = std.Io.Clock.real.now(io).toMilliseconds();
        while (true) {
            if (cwd.createFile(io, self.lockFilePath, .{ .exclusive = true })) |lock_file| {
                lock_file.close(io);
                return;
            }
            else |_| {
                if (std.Io.Clock.real.now(io).toMilliseconds() - startTime > maxWaitMs) {
                    // Stale lock: remove and take ownership.
                    cwd.deleteFile(io, self.lockFilePath) catch {};
                    const lock_file = try cwd.createFile(io, self.lockFilePath, .{ .exclusive = true });
                    lock_file.close(io);
                    return;
                }

                // Short wait before retrying.
                try io.sleep(.fromMilliseconds(5), .awake);
            }
        }
    }

    //
    // Releases the lock taken by acquireLock.
    //
    fn releaseLock(self: *TestUuidGenerator, io: std.Io) void {
        std.Io.Dir.cwd().deleteFile(io, self.lockFilePath) catch {};
    }

    //
    // Deletes the counter and lock files so the sequence restarts.
    //
    pub fn reset(self: *TestUuidGenerator, io: std.Io) void {
        const cwd = std.Io.Dir.cwd();
        cwd.deleteFile(io, self.counterFilePath) catch {};
        cwd.deleteFile(io, self.lockFilePath) catch {};
    }

    //
    // Generates the UUID for a counter value. Same algorithm as the in-memory TestUuidGenerator in utils,
    // so it is shared with utils-zig (which reproduces the JavaScript number semantics exactly).
    //
    fn generateDeterministicUuid(allocator: std.mem.Allocator, counter: i64) ![]const u8 {
        return utils.test_uuid_generator.TestUuidGenerator.generateDeterministicUuid(allocator, counter);
    }

    //
    // Type-erased generate for the vtable.
    //
    fn generateErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror![]const u8 {
        const self: *TestUuidGenerator = @ptrCast(@alignCast(ptr));
        return self.generate(allocator, io);
    }
};
