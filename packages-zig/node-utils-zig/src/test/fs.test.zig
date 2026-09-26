const std = @import("std");
const builtin = @import("builtin");
const node_utils = @import("node-utils-zig");
const utils = @import("utils-zig");
const fs = node_utils.fs;
const errors = utils.errors;

//
// Creates a unique temp file path under the package's .zig-cache directory.
//
fn tempFilePath(allocator: std.mem.Allocator, io: std.Io, suffix: []const u8) ![]const u8 {
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/photosphere-fs-test-{x}-{s}", .{ std.mem.readInt(u64, &random_bytes, .little), suffix });
}

//
// Builds an object value from key/value pairs.
//
fn makeObject(allocator: std.mem.Allocator, keys: []const []const u8, values: []const std.json.Value) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    for (keys, values) |key, value| {
        try object.put(allocator, key, value);
    }
    return .{ .object = object };
}

test "round-trips a flat object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try tempFilePath(allocator, io, "flat.toml");
    const original = try makeObject(allocator, &.{ "name", "count", "flag" }, &.{ .{ .string = "test" }, .{ .integer = 42 }, .{ .bool = true } });

    try fs.writeToml(allocator, io, filePath, original);
    const result = try fs.readToml(allocator, io, filePath);

    try std.testing.expectEqualStrings("test", result.object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 42), result.object.get("count").?.integer);
    try std.testing.expectEqual(true, result.object.get("flag").?.bool);

    try std.Io.Dir.cwd().deleteFile(io, filePath);
}

test "round-trips an object with string arrays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try tempFilePath(allocator, io, "arrays.toml");
    var tags = std.json.Array.init(allocator);
    try tags.appendSlice(&.{ .{ .string = "alpha" }, .{ .string = "beta" }, .{ .string = "gamma" } });
    const original = try makeObject(allocator, &.{"tags"}, &.{.{ .array = tags }});

    try fs.writeToml(allocator, io, filePath, original);
    const result = try fs.readToml(allocator, io, filePath);

    const result_tags = result.object.get("tags").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), result_tags.len);
    try std.testing.expectEqualStrings("alpha", result_tags[0].string);
    try std.testing.expectEqualStrings("beta", result_tags[1].string);
    try std.testing.expectEqualStrings("gamma", result_tags[2].string);

    try std.Io.Dir.cwd().deleteFile(io, filePath);
}

test "round-trips a nested object (array of tables)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try tempFilePath(allocator, io, "nested.toml");
    var items = std.json.Array.init(allocator);
    try items.append(try makeObject(allocator, &.{ "name", "value" }, &.{ .{ .string = "a" }, .{ .integer = 1 } }));
    try items.append(try makeObject(allocator, &.{ "name", "value" }, &.{ .{ .string = "b" }, .{ .integer = 2 } }));
    const original = try makeObject(allocator, &.{"items"}, &.{.{ .array = items }});

    try fs.writeToml(allocator, io, filePath, original);
    const result = try fs.readToml(allocator, io, filePath);

    const result_items = result.object.get("items").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), result_items.len);
    try std.testing.expectEqualStrings("a", result_items[0].object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 2), result_items[1].object.get("value").?.integer);

    try std.Io.Dir.cwd().deleteFile(io, filePath);
}

test "writeToml creates parent directories if missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try tempFilePath(allocator, io, "subdir/nested.toml");
    const original = try makeObject(allocator, &.{"key"}, &.{.{ .string = "value" }});

    try fs.writeToml(allocator, io, filePath, original);
    const result = try fs.readToml(allocator, io, filePath);

    try std.testing.expectEqualStrings("value", result.object.get("key").?.string);

    try std.Io.Dir.cwd().deleteTree(io, std.fs.path.dirname(filePath).?);
}

test "readJson parses a JSON file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try tempFilePath(allocator, io, "data.json");
    try fs.outputFile(allocator, io, filePath, "{\"databases\": [{\"name\": \"a\"}], \"count\": 3}");

    const result = try fs.readJson(allocator, io, filePath);

    try std.testing.expectEqualStrings("a", result.object.get("databases").?.array.items[0].object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 3), result.object.get("count").?.integer);
    try std.Io.Dir.cwd().deleteFile(io, filePath);
}

test "readJson and readToml fail when the file does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try tempFilePath(allocator, io, "missing.json");
    try std.testing.expectError(error.FileNotFound, fs.readJson(allocator, io, filePath));
    try std.testing.expectError(error.FileNotFound, fs.readToml(allocator, io, filePath));
}

test "ensureDir creates nested directories and accepts existing ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const dirPath = try tempFilePath(allocator, io, "dir");
    const nestedPath = try std.fmt.allocPrint(allocator, "{s}/a/b", .{dirPath});

    try fs.ensureDir(io, nestedPath);
    try std.testing.expect(fs.pathExists(io, nestedPath));
    try fs.ensureDir(io, nestedPath);
    try fs.ensureDirSync(io, nestedPath);

    try fs.remove(io, dirPath);
    try std.testing.expect(!fs.pathExists(io, dirPath));
}

test "ensureDir throws when the path is a file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try tempFilePath(allocator, io, "file.txt");
    try fs.outputFile(allocator, io, filePath, "data");

    try std.testing.expectError(error.Thrown, fs.ensureDir(io, filePath));
    const expected = try std.fmt.allocPrint(allocator, "Path exists but is not a directory: {s}", .{filePath});
    try std.testing.expectEqualStrings(expected, errors.lastErrorMessage());

    try fs.remove(io, filePath);
}

test "ensureFileDir creates the parent directory of a file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const dirPath = try tempFilePath(allocator, io, "parent");
    const filePath = try std.fmt.allocPrint(allocator, "{s}/child/file.txt", .{dirPath});

    try fs.ensureFileDir(io, filePath);

    try std.testing.expect(fs.pathExists(io, std.fs.path.dirname(filePath).?));
    try std.testing.expect(!fs.pathExists(io, filePath));
    try fs.remove(io, dirPath);
}

test "pathExists reports files and missing paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try tempFilePath(allocator, io, "exists.txt");

    try std.testing.expect(!fs.pathExists(io, filePath));
    try fs.outputFile(allocator, io, filePath, "data");
    try std.testing.expect(fs.pathExists(io, filePath));
    try fs.remove(io, filePath);
    try std.testing.expect(!fs.pathExists(io, filePath));
}

test "remove ignores missing paths and removes directory trees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const dirPath = try tempFilePath(allocator, io, "tree");

    try fs.remove(io, dirPath);
    try fs.outputFile(allocator, io, try std.fmt.allocPrint(allocator, "{s}/a/b.txt", .{dirPath}), "b");
    try fs.outputFile(allocator, io, try std.fmt.allocPrint(allocator, "{s}/c.txt", .{dirPath}), "c");
    try fs.remove(io, dirPath);
    try std.testing.expect(!fs.pathExists(io, dirPath));
}

test "outputFile writes the data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try tempFilePath(allocator, io, "out/data.txt");

    try fs.outputFile(allocator, io, filePath, "hello");

    const data = try std.Io.Dir.cwd().readFileAlloc(io, filePath, allocator, .unlimited);
    try std.testing.expectEqualStrings("hello", data);
    try fs.remove(io, std.fs.path.dirname(filePath).?);
}

test "getProcessTmpDir returns PHOTOSPHERE_TMP_DIR/tmp when set, otherwise the system temp dir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var environ_map = std.process.Environ.Map.init(allocator);
    node_utils.process_env.setEnvironMap(&environ_map);
    defer node_utils.process_env.setEnvironMap(null);

    const currentPath = try std.process.currentPathAlloc(io, allocator);

    // Windows paths and temp dir variables follow Node's win32 rules.
    if (builtin.os.tag == .windows) {
        try environ_map.put("TEMP", "C:\\custom\\tmp\\");
        try std.testing.expectEqualStrings("C:\\custom\\tmp", try fs.getProcessTmpDir(allocator, io));

        _ = environ_map.swapRemove("TEMP");
        try environ_map.put("SystemRoot", "C:\\Windows");
        try std.testing.expectEqualStrings("C:\\Windows\\temp", try fs.getProcessTmpDir(allocator, io));

        try environ_map.put("PHOTOSPHERE_TMP_DIR", "C:\\isolated\\test");
        try std.testing.expectEqualStrings("C:\\isolated\\test\\tmp", try fs.getProcessTmpDir(allocator, io));

        try environ_map.put("PHOTOSPHERE_TMP_DIR", "relative\\dir");
        const expected = try std.fmt.allocPrint(allocator, "{s}\\relative\\dir\\tmp", .{currentPath});
        try std.testing.expectEqualStrings(expected, try fs.getProcessTmpDir(allocator, io));
    }
    else {
        try environ_map.put("TMPDIR", "/custom/tmp/");
        try std.testing.expectEqualStrings("/custom/tmp", try fs.getProcessTmpDir(allocator, io));

        _ = environ_map.swapRemove("TMPDIR");
        try std.testing.expectEqualStrings("/tmp", try fs.getProcessTmpDir(allocator, io));

        try environ_map.put("PHOTOSPHERE_TMP_DIR", "/isolated/test");
        try std.testing.expectEqualStrings("/isolated/test/tmp", try fs.getProcessTmpDir(allocator, io));

        try environ_map.put("PHOTOSPHERE_TMP_DIR", "relative/dir");
        const expected = try std.fmt.allocPrint(allocator, "{s}/relative/dir/tmp", .{currentPath});
        try std.testing.expectEqualStrings(expected, try fs.getProcessTmpDir(allocator, io));
    }
}

test "osTmpDir follows the os.tmpdir() rules of the platform" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var environ_map = std.process.Environ.Map.init(allocator);
    node_utils.process_env.setEnvironMap(&environ_map);
    defer node_utils.process_env.setEnvironMap(null);

    if (builtin.os.tag == .windows) {
        try environ_map.put("SystemRoot", "C:\\Windows");
        try std.testing.expectEqualStrings("C:\\Windows\\temp", try fs.osTmpDir(allocator));
        try environ_map.put("TMP", "D:\\tmp\\");
        try std.testing.expectEqualStrings("D:\\tmp", try fs.osTmpDir(allocator));
        try environ_map.put("TEMP", "E:\\");
        try std.testing.expectEqualStrings("E:\\", try fs.osTmpDir(allocator));
    }
    else {
        try std.testing.expectEqualStrings("/tmp", try fs.osTmpDir(allocator));
        try environ_map.put("TEMP", "/temp/");
        try std.testing.expectEqualStrings("/temp", try fs.osTmpDir(allocator));
        try environ_map.put("TMP", "/tmp2");
        try std.testing.expectEqualStrings("/tmp2", try fs.osTmpDir(allocator));
        try environ_map.put("TMPDIR", "/");
        try std.testing.expectEqualStrings("/", try fs.osTmpDir(allocator));
    }
}

//
// Creates a file path inside a directory of this test's own (the directory is created).
//
fn tempFilePathInOwnDir(allocator: std.mem.Allocator, io: std.Io, suffix: []const u8) ![]const u8 {
    const dirPath = try tempFilePath(allocator, io, "dir");
    try fs.ensureDir(io, dirPath);
    return std.fs.path.join(allocator, &.{ dirPath, suffix });
}

//
// Writes `content` to `filePath` with outputFile, for running writers concurrently.
//
fn outputFileTask(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, content: []const u8) void {
    fs.outputFile(allocator, io, filePath, content) catch |err| {
        std.debug.panic("outputFile failed: {s}", .{@errorName(err)});
    };
}

test "concurrent writes to the same file never leave a torn result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try tempFilePathInOwnDir(allocator, io, "atomic-concurrent.txt");

    // Each writer emits content of a different length so a byte-level interleave
    // would produce a mix that matches none of the inputs. Distinct lengths make
    // any torn write detectable.
    var contents: [20][]const u8 = undefined;
    var task_allocators: [20]std.heap.ArenaAllocator = undefined;
    for (&contents, 0..) |*content, index| {
        const padding = try allocator.alloc(u8, index);
        @memset(padding, 'x');
        content.* = try std.fmt.allocPrint(allocator, "value-{d}-{s}", .{ index, padding });
        task_allocators[index] = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    }
    defer {
        for (&task_allocators) |*task_allocator| {
            task_allocator.deinit();
        }
    }

    var group: std.Io.Group = .init;
    for (contents, 0..) |content, index| {
        group.async(io, outputFileTask, .{ task_allocators[index].allocator(), io, filePath, content });
    }
    try group.await(io);

    const finalContent = try std.Io.Dir.cwd().readFileAlloc(io, filePath, allocator, .unlimited);

    // The file must equal exactly one of the complete writes, never a fragment or a blend.
    var matched = false;
    for (contents) |content| {
        if (std.mem.eql(u8, content, finalContent)) {
            matched = true;
        }
    }
    try std.testing.expect(matched);

    try std.Io.Dir.cwd().deleteFile(io, filePath);
}

test "leaves no temporary files behind after writing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try tempFilePathInOwnDir(allocator, io, "atomic-cleanup.txt");

    try fs.outputFile(allocator, io, filePath, "done");

    var dir = try std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(filePath).?, .{ .iterate = true });
    defer dir.close(io);
    const baseName = std.fs.path.basename(filePath);
    const tempPrefix = try std.fmt.allocPrint(allocator, "{s}.tmp-", .{baseName});
    var leftoverTempFiles: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (std.mem.startsWith(u8, entry.name, tempPrefix)) {
            leftoverTempFiles += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), leftoverTempFiles);

    try std.Io.Dir.cwd().deleteFile(io, filePath);
}

//
// Identity parse for the updateFileOptimistic tests (`raw => raw`).
//
const IdentityParse = struct {
    // Unused. Present so the parser is a value with methods.
    unused: u8 = 0,

    //
    // Returns the text as it is.
    //
    pub fn run(self: IdentityParse, allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
        _ = self;
        _ = allocator;
        return raw;
    }
};

//
// Identity serialize for the updateFileOptimistic tests (`value => value`).
//
const IdentitySerialize = struct {
    // Unused. Present so the serializer is a value with methods.
    unused: u8 = 0,

    //
    // Returns the value as it is.
    //
    pub fn run(self: IdentitySerialize, allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
        _ = self;
        _ = allocator;
        return value;
    }
};

//
// A mutator for the updateFileOptimistic tests. Appends `suffix` to the current value and, when
// `externalWriteFile` is set, first changes the file underneath the update the way a concurrent
// writer would: once when `injectOnce` is set, otherwise on every attempt with a growing size.
//
const AppendMutator = struct {
    // The text appended to the current value.
    suffix: []const u8,

    // The file to change underneath the update, or null to change nothing.
    externalWriteFile: ?[]const u8,

    // Whether the external write happens only on the first call.
    injectOnce: bool,

    // Whether the external write has happened.
    injected: bool = false,

    // Grows with each external write so each has a different size.
    external: usize = 1,

    // The io used for the external write.
    io: std.Io,

    //
    // Applies the change.
    //
    pub fn run(self: *AppendMutator, allocator: std.mem.Allocator, current: []const u8) ![]const u8 {
        if (self.externalWriteFile) |externalPath| {
            if (self.injectOnce) {
                if (!self.injected) {
                    self.injected = true;

                    // Simulate a concurrent writer changing the file after our read, before the check.
                    try std.Io.Dir.cwd().writeFile(self.io, .{
                        .sub_path = externalPath,
                        .data = "changed-by-other",
                    });
                }
            }
            else {
                // Grow the file each attempt to a size that always differs from the current file,
                // so the pre-move check always sees a conflict regardless of timestamp resolution.
                const grown = try allocator.alloc(u8, self.external + 4);
                @memset(grown, 'y');
                try std.Io.Dir.cwd().writeFile(self.io, .{
                    .sub_path = externalPath,
                    .data = grown,
                });
                self.external += 1;
            }
        }
        return std.mem.concat(allocator, u8, &.{ current, self.suffix });
    }
};

test "uses the fallback, applies the mutator, and serializes the result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try tempFilePathInOwnDir(allocator, io, "optimistic-generic.txt");

    // Identity parse/serialize so the test exercises the core loop independent of any format.
    var mutator: AppendMutator = .{
        .suffix = "-mutated",
        .externalWriteFile = null,
        .injectOnce = true,
        .io = io,
    };
    try fs.updateFileOptimistic([]const u8, allocator, io, filePath, "seed", &mutator, IdentityParse{}, IdentitySerialize{}, 3);

    const content = try std.Io.Dir.cwd().readFileAlloc(io, filePath, allocator, .unlimited);
    try std.testing.expectEqualStrings("seed-mutated", content);

    try std.Io.Dir.cwd().deleteFile(io, filePath);
}

test "updateFileOptimistic reloads and re-applies the mutator when the file changed under it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try tempFilePathInOwnDir(allocator, io, "optimistic-generic-retry.txt");
    try fs.outputFile(allocator, io, filePath, "base");

    var mutator: AppendMutator = .{
        .suffix = "!",
        .externalWriteFile = filePath,
        .injectOnce = true,
        .io = io,
    };
    try fs.updateFileOptimistic([]const u8, allocator, io, filePath, "", &mutator, IdentityParse{}, IdentitySerialize{}, 3);

    const content = try std.Io.Dir.cwd().readFileAlloc(io, filePath, allocator, .unlimited);
    try std.testing.expectEqualStrings("changed-by-other!", content);

    try std.Io.Dir.cwd().deleteFile(io, filePath);
}

test "updateFileOptimistic throws after the configured retries when the file keeps changing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try tempFilePathInOwnDir(allocator, io, "optimistic-generic-exhaust.txt");
    try fs.outputFile(allocator, io, filePath, "x");

    var mutator: AppendMutator = .{
        .suffix = "!",
        .externalWriteFile = filePath,
        .injectOnce = false,
        .io = io,
    };
    try std.testing.expectError(error.Thrown, fs.updateFileOptimistic([]const u8, allocator, io, filePath, "", &mutator, IdentityParse{}, IdentitySerialize{}, 2));
    try std.testing.expect(std.mem.indexOf(u8, errors.lastErrorMessage(), "kept changing") != null);

    try std.Io.Dir.cwd().deleteFile(io, filePath);
}

//
// A raw mutator for the updateFileRawOptimistic tests: records what it was given and returns
// `result`, or appends `suffix` to the current bytes when `result` is null. Like AppendMutator it
// can change the file underneath the update.
//
const RawMutator = struct {
    // The bytes to return, or null to append `suffix` to the current bytes.
    result: ?[]const u8,

    // The text appended to the current bytes when `result` is null.
    suffix: []const u8,

    // Whether the mutator has been called.
    called: bool = false,

    // The bytes the mutator was last given (null for a missing file).
    receivedCurrent: ?[]const u8 = null,

    // The shared external-writer behaviour.
    external: AppendMutator,

    //
    // Applies the change.
    //
    pub fn run(self: *RawMutator, allocator: std.mem.Allocator, current: ?[]const u8) ![]const u8 {
        self.called = true;
        self.receivedCurrent = current;
        if (self.result) |result| {
            return result;
        }
        return self.external.run(allocator, current orelse "");
    }
};

test "passes undefined for a missing file and writes the mutator result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try tempFilePathInOwnDir(allocator, io, "optimistic-raw-create.bin");

    // Bytes that are not valid utf8, proving the raw path never decodes the content.
    const newBytes = [_]u8{ 0x00, 0xff, 0xfe, 0x01 };
    var mutator: RawMutator = .{
        .result = &newBytes,
        .suffix = "",
        .receivedCurrent = "not called",
        .external = .{
            .suffix = "",
            .externalWriteFile = null,
            .injectOnce = true,
            .io = io,
        },
    };
    try fs.updateFileRawOptimistic(allocator, io, filePath, &mutator, 3);

    try std.testing.expect(mutator.called);
    try std.testing.expect(mutator.receivedCurrent == null);
    const written = try std.Io.Dir.cwd().readFileAlloc(io, filePath, allocator, .unlimited);
    try std.testing.expectEqualSlices(u8, &newBytes, written);

    try std.Io.Dir.cwd().deleteFile(io, filePath);
}

test "passes the existing bytes to the mutator and publishes its result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try tempFilePathInOwnDir(allocator, io, "optimistic-raw-update.bin");
    const originalBytes = [_]u8{ 0x10, 0x20, 0x30 };
    try fs.outputFile(allocator, io, filePath, &originalBytes);

    var mutator: RawMutator = .{
        .result = null,
        .suffix = "",
        .external = .{
            .suffix = &.{0x40},
            .externalWriteFile = null,
            .injectOnce = true,
            .io = io,
        },
    };
    try fs.updateFileRawOptimistic(allocator, io, filePath, &mutator, 3);

    try std.testing.expectEqualSlices(u8, &originalBytes, mutator.receivedCurrent.?);
    const written = try std.Io.Dir.cwd().readFileAlloc(io, filePath, allocator, .unlimited);
    try std.testing.expectEqualSlices(u8, &.{ 0x10, 0x20, 0x30, 0x40 }, written);

    try std.Io.Dir.cwd().deleteFile(io, filePath);
}

test "updateFileRawOptimistic reloads and re-applies the mutator when the file changed under it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try tempFilePathInOwnDir(allocator, io, "optimistic-raw-retry.bin");
    try fs.outputFile(allocator, io, filePath, "base");

    var mutator: RawMutator = .{
        .result = null,
        .suffix = "",
        .external = .{
            .suffix = "!",
            .externalWriteFile = filePath,
            .injectOnce = true,
            .io = io,
        },
    };
    try fs.updateFileRawOptimistic(allocator, io, filePath, &mutator, 3);

    const written = try std.Io.Dir.cwd().readFileAlloc(io, filePath, allocator, .unlimited);
    try std.testing.expectEqualStrings("changed-by-other!", written);

    try std.Io.Dir.cwd().deleteFile(io, filePath);
}

test "updateFileRawOptimistic throws after the configured retries when the file keeps changing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try tempFilePathInOwnDir(allocator, io, "optimistic-raw-exhaust.bin");
    try fs.outputFile(allocator, io, filePath, "x");

    var mutator: RawMutator = .{
        .result = null,
        .suffix = "",
        .external = .{
            .suffix = "!",
            .externalWriteFile = filePath,
            .injectOnce = false,
            .io = io,
        },
    };
    try std.testing.expectError(error.Thrown, fs.updateFileRawOptimistic(allocator, io, filePath, &mutator, 2));
    try std.testing.expect(std.mem.indexOf(u8, errors.lastErrorMessage(), "kept changing") != null);

    // The lock is released on the way out.
    const lockPath = try std.fmt.allocPrint(allocator, "{s}.lock", .{filePath});
    try std.testing.expect(!fs.pathExists(io, lockPath));

    try std.Io.Dir.cwd().deleteFile(io, filePath);
}

test "throws a failure that is not contention straight away, without retrying" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    // Renaming onto a path held by a non-empty directory fails for a reason that has nothing to
    // do with anything holding the file, so it must come back at once rather than being tried ten
    // times over a second. The elapsed time is what tells those apart.
    const occupiedPath = try tempFilePathInOwnDir(allocator, io, "occupied");
    try fs.outputFile(allocator, io, try std.fs.path.join(allocator, &.{ occupiedPath, "child.txt" }), "in the way");

    const startedAt = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    try std.testing.expect(std.meta.isError(fs.outputFile(allocator, io, occupiedPath, "replacement")));
    try std.testing.expect(std.Io.Timestamp.now(io, .awake).toMilliseconds() - startedAt < 500);

    try fs.remove(io, std.fs.path.dirname(occupiedPath).?);
}

test "still writes normally when nothing refuses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try tempFilePathInOwnDir(allocator, io, "rename-ok.txt");

    try fs.outputFile(allocator, io, filePath, "written");

    const content = try std.Io.Dir.cwd().readFileAlloc(io, filePath, allocator, .unlimited);
    try std.testing.expectEqualStrings("written", content);

    try std.Io.Dir.cwd().deleteFile(io, filePath);
}

test "getConfigDir is .config/photosphere under the home directory on desktop and the CLI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var environ_map = std.process.Environ.Map.init(allocator);
    node_utils.process_env.setEnvironMap(&environ_map);
    defer node_utils.process_env.setEnvironMap(null);
    const home_variable = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    try environ_map.put(home_variable, "/some-home");

    const expected = try std.fs.path.join(allocator, &.{ "/some-home", ".config", "photosphere" });
    try std.testing.expectEqualStrings(expected, try fs.getConfigDir(allocator));
}

test "getConfigDir is the storage sandbox root when there is no home directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var environ_map = std.process.Environ.Map.init(allocator);
    node_utils.process_env.setEnvironMap(&environ_map);
    defer node_utils.process_env.setEnvironMap(null);

    try std.testing.expectEqualStrings(".", try fs.getConfigDir(allocator));
}

test "getConfigDir uses PHOTOSPHERE_CONFIG_DIR when it is set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var environ_map = std.process.Environ.Map.init(allocator);
    node_utils.process_env.setEnvironMap(&environ_map);
    defer node_utils.process_env.setEnvironMap(null);
    const home_variable = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    try environ_map.put(home_variable, "/some-home");
    try environ_map.put("PHOTOSPHERE_CONFIG_DIR", "/chosen-config");

    try std.testing.expectEqualStrings("/chosen-config", try fs.getConfigDir(allocator));
}

test "getConfigDir uses the override on a device too, where there is no home directory to fall back on" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var environ_map = std.process.Environ.Map.init(allocator);
    node_utils.process_env.setEnvironMap(&environ_map);
    defer node_utils.process_env.setEnvironMap(null);
    try environ_map.put("PHOTOSPHERE_CONFIG_DIR", "/chosen-config");

    try std.testing.expectEqualStrings("/chosen-config", try fs.getConfigDir(allocator));
}

test "a file that does not exist reads as undefined" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    // Absence is not an error, unlike readToml: the config file does not exist until something
    // writes it, and a caller that had to check first would be checking then reading, which a
    // concurrent writer can arrive between.
    const filePath = try tempFilePath(allocator, io, "missing.yaml");

    try std.testing.expect(try fs.readYaml(allocator, io, filePath) == null);
}

test "a file reads back as the object it holds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try tempFilePath(allocator, io, "round-trip.yaml");
    try fs.outputFile(allocator, io, filePath, "name: test\ncount: 42\nflag: true\nnested:\n  list:\n    - a\n    - b\n");

    const result = (try fs.readYaml(allocator, io, filePath)).?;

    try std.testing.expectEqualStrings("{\"name\":\"test\",\"count\":42,\"flag\":true,\"nested\":{\"list\":[\"a\",\"b\"]}}", try std.json.Stringify.valueAlloc(allocator, result, .{}));
    try std.Io.Dir.cwd().deleteFile(io, filePath);
}

test "an empty file reads as undefined rather than as an empty object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try tempFilePath(allocator, io, "empty.yaml");
    try fs.outputFile(allocator, io, filePath, "");

    try std.testing.expect(try fs.readYaml(allocator, io, filePath) == null);
    try std.Io.Dir.cwd().deleteFile(io, filePath);
}

test "text that is not YAML throws rather than reading as nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    // A caller that wants the defaults for an unreadable file decides that for itself. Returning
    // undefined here would make "there is no file" and "the file is broken" indistinguishable.
    const filePath = try tempFilePath(allocator, io, "broken.yaml");
    try fs.outputFile(allocator, io, filePath, "a:\n  b: 1\n   c: [");

    try std.testing.expectError(error.Thrown, fs.readYaml(allocator, io, filePath));
    try std.Io.Dir.cwd().deleteFile(io, filePath);
}

//
// A mutator for the updateYaml tests: adds `amount` to the `count` of the current document, optionally
// writing the file itself first (a concurrent writer) on the first call or on every call.
//
const CountMutator = struct {
    // What is added to the count.
    amount: i64,

    // The file a concurrent writer changes, or null for none.
    externalWriteFile: ?[]const u8,

    // True to change the file on the first call only, false to change it on every call.
    injectOnce: bool,

    // How many times the file has been changed from outside.
    external: usize = 0,

    // Used to write the file.
    io: std.Io,

    //
    // Returns `{ count: current.count + amount }`.
    //
    pub fn run(self: *CountMutator, allocator: std.mem.Allocator, current: std.json.Value) !std.json.Value {
        if (self.externalWriteFile) |externalPath| {
            if (!self.injectOnce or self.external == 0) {
                self.external += 1;
                var text: std.ArrayList(u8) = .empty;
                try text.print(allocator, "count: {d}\n", .{if (self.injectOnce) 99 else self.external});
                var padIndex: usize = 0;
                while (!self.injectOnce and padIndex < self.external) {
                    try text.appendSlice(allocator, "# pad\n");
                    padIndex += 1;
                }
                try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = externalPath, .data = text.items });
            }
        }
        var object: std.json.ObjectMap = .empty;
        try object.put(allocator, "count", .{ .integer = current.object.get("count").?.integer + self.amount });
        return .{ .object = object };
    }
};

//
// Makes `{ count: value }`.
//
fn countDocument(allocator: std.mem.Allocator, value: i64) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "count", .{ .integer = value });
    return .{ .object = object };
}

//
// Reads the count of a YAML file.
//
fn readCount(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !i64 {
    return (try fs.readYaml(allocator, io, filePath)).?.object.get("count").?.integer;
}

test "uses the fallback and writes when the file does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try tempFilePathInOwnDir(allocator, io, "update-yaml-new.yaml");

    var mutator: CountMutator = .{ .amount = 5, .externalWriteFile = null, .injectOnce = true, .io = io };
    try fs.updateYaml(allocator, io, filePath, try countDocument(allocator, 0), &mutator, 3);

    try std.testing.expectEqual(@as(i64, 5), try readCount(allocator, io, filePath));
    try std.testing.expectEqualStrings("count: 5\n", try std.Io.Dir.cwd().readFileAlloc(io, filePath, allocator, .unlimited));
    try std.Io.Dir.cwd().deleteFile(io, filePath);
}

test "reads existing contents and applies the mutator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try tempFilePathInOwnDir(allocator, io, "update-yaml-existing.yaml");
    try fs.outputFile(allocator, io, filePath, "count: 10\n");

    var mutator: CountMutator = .{ .amount = 1, .externalWriteFile = null, .injectOnce = true, .io = io };
    try fs.updateYaml(allocator, io, filePath, try countDocument(allocator, 0), &mutator, 3);

    try std.testing.expectEqual(@as(i64, 11), try readCount(allocator, io, filePath));
    try std.Io.Dir.cwd().deleteFile(io, filePath);
}

test "uses the fallback when the file is there but empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try tempFilePathInOwnDir(allocator, io, "update-yaml-empty.yaml");
    try fs.outputFile(allocator, io, filePath, "");

    var mutator: CountMutator = .{ .amount = 1, .externalWriteFile = null, .injectOnce = true, .io = io };
    try fs.updateYaml(allocator, io, filePath, try countDocument(allocator, 7), &mutator, 3);

    try std.testing.expectEqual(@as(i64, 8), try readCount(allocator, io, filePath));
    try std.Io.Dir.cwd().deleteFile(io, filePath);
}

test "updateYaml reloads and re-applies the mutator when the file changed under it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try tempFilePathInOwnDir(allocator, io, "update-yaml-retry.yaml");
    try fs.outputFile(allocator, io, filePath, "count: 0\n");

    // Simulate a concurrent writer changing the file after our read but before the pre-move check.
    var mutator: CountMutator = .{ .amount = 1, .externalWriteFile = filePath, .injectOnce = true, .io = io };
    try fs.updateYaml(allocator, io, filePath, try countDocument(allocator, 0), &mutator, 3);

    // The mutator ran twice: once on the stale read (discarded), once on the reloaded value 99 -> 100.
    try std.testing.expectEqual(@as(i64, 100), try readCount(allocator, io, filePath));
    try std.Io.Dir.cwd().deleteFile(io, filePath);
}

test "updateYaml throws after the configured retries when the file keeps changing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try tempFilePathInOwnDir(allocator, io, "update-yaml-exhaust.yaml");
    try fs.outputFile(allocator, io, filePath, "count: 0\n");

    // Change the file under every attempt (growing its size) so the pre-move check always
    // sees a conflict regardless of mtime resolution.
    var mutator: CountMutator = .{ .amount = 1, .externalWriteFile = filePath, .injectOnce = false, .io = io };
    try std.testing.expectError(error.Thrown, fs.updateYaml(allocator, io, filePath, try countDocument(allocator, 0), &mutator, 2));
    try std.testing.expect(std.mem.indexOf(u8, errors.lastErrorMessage(), "kept changing") != null);
    try std.Io.Dir.cwd().deleteFile(io, filePath);
}
