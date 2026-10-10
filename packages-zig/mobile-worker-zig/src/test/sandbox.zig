//
// A temporary working directory standing in for the app's storage sandbox, with the task context the handlers take.
//
// The handlers reach storage through FileStorage, which resolves relative paths against the process working directory on a
// host and against the app's sandbox root on a device, so the tests run from a temporary directory.
//

const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const task_queue_zig = @import("task-queue-zig");
const temp_dirs = @import("../../../node-api-zig/src/test/temp-dirs.zig");
const mock_log = @import("../../../node-api-zig/src/test/mock-log.zig");
const test_environment = @import("../../../node-api-zig/src/test/test-environment.zig");
const TaskContext = task_queue_zig.task_context.TaskContext;
const ITaskContext = task_queue_zig.types.ITaskContext;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const TestTimestampProvider = node_utils.test_timestamp_provider.TestTimestampProvider;

//
// A uuid generator that always gives the same uuid.
//
pub const FixedUuidGenerator = struct {
    // The uuid every call gives.
    uuid: []const u8,

    //
    // Gets the IUuidGenerator interface for this generator.
    //
    pub fn uuidGenerator(self: *FixedUuidGenerator) IUuidGenerator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // The functions of the generator.
    //
    const vtable: IUuidGenerator.VTable = .{
        .generate = generate,
    };

    //
    // Gives the uuid.
    //
    fn generate(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror![]const u8 {
        _ = io;
        const self: *FixedUuidGenerator = @ptrCast(@alignCast(ptr));
        return allocator.dupe(u8, self.uuid);
    }
};

//
// Drops a message: the handlers under test send none.
//
fn ignoreMessage(context: ?*anyopaque, message: std.json.Value) void {
    _ = context;
    _ = message;
}

//
// The temporary sandbox. Declare it, call init on it in place, and call deinit when the test is done.
//
pub const Sandbox = struct {
    // Allocates everything the test makes.
    arena: std.heap.ArenaAllocator,

    // The io the handlers use.
    io: std.Io,

    // The absolute path of the temporary directory.
    tempDir: []const u8,

    // The directory the whole test program owns, which holds the config directory the sandbox puts back.
    processDir: []const u8,

    // The working directory before the test changed it.
    previousCwd: []const u8,

    // The uuid generator of the task context.
    fixedUuidGenerator: FixedUuidGenerator,

    // Deterministic time.
    timestampProvider: TestTimestampProvider,

    // The task context the handlers take.
    taskContext: TaskContext,

    // Swallows what the code under test logs.
    mutedLog: mock_log.MutedLog,

    //
    // Makes the temporary directory and changes into it.
    //
    pub fn init(self: *Sandbox) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.io = std.testing.io;
        // The environment the storage layer reads its config directory, vault and credentials from.
        self.processDir = try test_environment.setupEnvironment(self.io);
        const allocator = self.arena.allocator();
        self.previousCwd = try std.process.currentPathAlloc(self.io, allocator);
        self.tempDir = try temp_dirs.makeTempDir(allocator, self.io, "mobile-worker");
        try std.process.setCurrentPath(self.io, self.tempDir);
        // The config file the handlers read is in the config directory, which is the sandbox for the length of the test.
        try test_environment.setEnv("PHOTOSPHERE_CONFIG_DIR", self.tempDir);
        self.fixedUuidGenerator = .{
            .uuid = "test-session-id",
        };
        self.timestampProvider = .{};
        self.taskContext = TaskContext.init(self.fixedUuidGenerator.uuidGenerator(), self.timestampProvider.timestampProvider(), "test-session", "test-task", .{
            .context = null,
            .function = ignoreMessage,
        }, 10);
        self.mutedLog = .{};
        self.mutedLog.install();
    }

    //
    // Changes back to the directory the test started in and removes the temporary one.
    //
    pub fn deinit(self: *Sandbox) void {
        self.mutedLog.uninstall();
        const processConfigDir = std.fs.path.join(self.arena.allocator(), &.{ self.processDir, "config" }) catch {
            @panic("The config directory could not be put back after a test.");
        };
        test_environment.setEnv("PHOTOSPHERE_CONFIG_DIR", processConfigDir) catch {
            @panic("The config directory could not be put back after a test.");
        };
        std.process.setCurrentPath(self.io, self.previousCwd) catch {
            @panic("The working directory could not be put back after a test.");
        };
        temp_dirs.removeTempDir(self.io, self.tempDir);
        self.arena.deinit();
    }

    //
    // Gets the allocator of the test.
    //
    pub fn arenaAllocator(self: *Sandbox) std.mem.Allocator {
        return self.arena.allocator();
    }

    //
    // Gets the ITaskContext of the test.
    //
    pub fn context(self: *Sandbox) ITaskContext {
        return self.taskContext.taskContext();
    }

    //
    // Parses JSON text into a value.
    //
    pub fn json(self: *Sandbox, text: []const u8) !std.json.Value {
        return std.json.parseFromSliceLeaky(std.json.Value, self.arenaAllocator(), text, .{});
    }

    //
    // Writes the file at the path, relative to the sandbox, making its directory.
    //
    pub fn writeFile(self: *Sandbox, path: []const u8, text: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirname(path)) |directory| {
            try cwd.createDirPath(self.io, directory);
        }
        try cwd.writeFile(self.io, .{
            .sub_path = path,
            .data = text,
        });
    }
};

//
// Gets the value at the dotted path of an object, or null when any step of it is missing.
//
pub fn at(value: std.json.Value, path: []const u8) ?std.json.Value {
    var current = value;
    var steps = std.mem.splitScalar(u8, path, '.');
    while (steps.next()) |step| {
        if (current != .object) {
            return null;
        }
        current = current.object.get(step) orelse {
            return null;
        };
    }
    return current;
}

//
// Expects the value at the path to be this boolean.
//
pub fn expectBool(expected: bool, value: std.json.Value, path: []const u8) !void {
    const found = at(value, path) orelse {
        std.debug.print("Nothing at {s}\n", .{path});
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqual(expected, found.bool);
}

//
// Expects the value at the path to be this integer.
//
pub fn expectInteger(expected: i64, value: std.json.Value, path: []const u8) !void {
    const found = at(value, path) orelse {
        std.debug.print("Nothing at {s}\n", .{path});
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqual(expected, found.integer);
}

//
// Expects the value at the path to be this string.
//
pub fn expectString(expected: []const u8, value: std.json.Value, path: []const u8) !void {
    const found = at(value, path) orelse {
        std.debug.print("Nothing at {s}\n", .{path});
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqualStrings(expected, found.string);
}

//
// Expects the value at the path to be an empty array.
//
pub fn expectEmptyArray(value: std.json.Value, path: []const u8) !void {
    const found = at(value, path) orelse {
        std.debug.print("Nothing at {s}\n", .{path});
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqual(@as(usize, 0), found.array.items.len);
}

//
// Expects the value at the path to be an array of strings holding exactly these.
//
pub fn expectStrings(expected: []const []const u8, value: std.json.Value, path: []const u8) !void {
    const found = at(value, path) orelse {
        std.debug.print("Nothing at {s}\n", .{path});
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqual(expected.len, found.array.items.len);
    for (expected, 0..) |text, index| {
        try std.testing.expectEqualStrings(text, found.array.items[index].string);
    }
}

//
// Expects the values at the key of each object of the array at the path to be exactly these strings (the `type` of each step).
//
pub fn expectKeyStrings(expected: []const []const u8, key: []const u8, value: std.json.Value, path: []const u8) !void {
    const found = at(value, path) orelse {
        std.debug.print("Nothing at {s}\n", .{path});
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqual(expected.len, found.array.items.len);
    for (expected, 0..) |text, index| {
        try std.testing.expectEqualStrings(text, found.array.items[index].object.get(key).?.string);
    }
}

//
// Expects the value at the path to contain the text.
//
pub fn expectContains(needle: []const u8, value: std.json.Value, path: []const u8) !void {
    const found = at(value, path) orelse {
        std.debug.print("Nothing at {s}\n", .{path});
        return error.TestExpectedEqual;
    };
    if (std.mem.indexOf(u8, found.string, needle) == null) {
        std.debug.print("\"{s}\" does not contain \"{s}\"\n", .{ found.string, needle });
        return error.TestExpectedEqual;
    }
}

//
// Expects nothing to be at the path.
//
pub fn expectMissing(value: std.json.Value, path: []const u8) !void {
    try std.testing.expect(at(value, path) == null);
}

//
// Finds the step with the type, so a test can assert on what a task is queued with.
//
pub fn stepData(steps: std.json.Value, stepType: []const u8) ?std.json.Value {
    for (steps.array.items) |step| {
        if (std.mem.eql(u8, step.object.get("type").?.string, stepType)) {
            return step.object.get("data").?;
        }
    }
    return null;
}
