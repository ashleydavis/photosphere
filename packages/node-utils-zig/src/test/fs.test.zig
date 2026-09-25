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
    try fs.outputFile(io, filePath, "{\"databases\": [{\"name\": \"a\"}], \"count\": 3}");

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
    try fs.outputFile(io, filePath, "data");

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
    try fs.outputFile(io, filePath, "data");
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
    try fs.outputFile(io, try std.fmt.allocPrint(allocator, "{s}/a/b.txt", .{dirPath}), "b");
    try fs.outputFile(io, try std.fmt.allocPrint(allocator, "{s}/c.txt", .{dirPath}), "c");
    try fs.remove(io, dirPath);
    try std.testing.expect(!fs.pathExists(io, dirPath));
}

test "outputFile writes the data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try tempFilePath(allocator, io, "out/data.txt");

    try fs.outputFile(io, filePath, "hello");

    const data = try std.Io.Dir.cwd().readFileAlloc(io, filePath, allocator, .unlimited);
    try std.testing.expectEqualStrings("hello", data);
    try fs.remove(io, std.fs.path.dirname(filePath).?);
}

test "getProcessTmpDir returns TEST_TMP_DIR/tmp when set, otherwise the system temp dir" {
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

        try environ_map.put("TEST_TMP_DIR", "C:\\isolated\\test");
        try std.testing.expectEqualStrings("C:\\isolated\\test\\tmp", try fs.getProcessTmpDir(allocator, io));

        try environ_map.put("TEST_TMP_DIR", "relative\\dir");
        const expected = try std.fmt.allocPrint(allocator, "{s}\\relative\\dir\\tmp", .{currentPath});
        try std.testing.expectEqualStrings(expected, try fs.getProcessTmpDir(allocator, io));
    }
    else {
        try environ_map.put("TMPDIR", "/custom/tmp/");
        try std.testing.expectEqualStrings("/custom/tmp", try fs.getProcessTmpDir(allocator, io));

        _ = environ_map.swapRemove("TMPDIR");
        try std.testing.expectEqualStrings("/tmp", try fs.getProcessTmpDir(allocator, io));

        try environ_map.put("TEST_TMP_DIR", "/isolated/test");
        try std.testing.expectEqualStrings("/isolated/test/tmp", try fs.getProcessTmpDir(allocator, io));

        try environ_map.put("TEST_TMP_DIR", "relative/dir");
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
