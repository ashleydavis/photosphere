//
// Tests of the directory a relative database path is resolved against: the `dbs` directory in the app's data directory, which
// PHOTOSPHERE_DATA_DIR overrides when it is set. Each test gives the thread an environment of its own, so a variable set in the shell that runs the tests
// cannot change the answer, and puts the thread's environment back when it ends.
//

const std = @import("std");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const withTaskDataDir = node_api.database_base_dir.withTaskDataDir;
const TASK_DATA_DIR_KEY = node_api.database_base_dir.TASK_DATA_DIR_KEY;
const databaseBaseDir = node_api.database_base_dir.databaseBaseDir;
const taskDatabaseBaseDir = node_api.database_base_dir.taskDatabaseBaseDir;

test "databaseBaseDir is the dbs directory in the data directory when PHOTOSPHERE_DATA_DIR is not set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environment = std.process.Environ.Map.init(arena.allocator());
    const previous = node_utils.process_env.getEnvironMap();
    node_utils.process_env.setEnvironMap(&environment);
    defer node_utils.process_env.setEnvironMap(previous);

    try std.testing.expectEqualStrings(try std.fs.path.join(arena.allocator(), &.{ "/data/user/0/app/files", "dbs" }), try databaseBaseDir(arena.allocator(), "/data/user/0/app/files"));
}

test "databaseBaseDir is the dbs directory in the directory PHOTOSPHERE_DATA_DIR names when it is set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environment = std.process.Environ.Map.init(arena.allocator());
    try environment.put("PHOTOSPHERE_DATA_DIR", "/tmp/scenario-7/files");
    const previous = node_utils.process_env.getEnvironMap();
    node_utils.process_env.setEnvironMap(&environment);
    defer node_utils.process_env.setEnvironMap(previous);

    try std.testing.expectEqualStrings(try std.fs.path.join(arena.allocator(), &.{ "/tmp/scenario-7/files", "dbs" }), try databaseBaseDir(arena.allocator(), "/data/user/0/app/files"));
}

test "databaseBaseDir is the working directory, with no dbs added, for an empty data directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environment = std.process.Environ.Map.init(arena.allocator());
    const previous = node_utils.process_env.getEnvironMap();
    node_utils.process_env.setEnvironMap(&environment);
    defer node_utils.process_env.setEnvironMap(previous);

    try std.testing.expectEqualStrings("", try databaseBaseDir(arena.allocator(), ""));
}

test "withTaskDataDir copies an object and adds the data directory, leaving the given data as it was" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var given: std.json.ObjectMap = .empty;
    try given.put(allocator, "databasePath", .{
        .string = "my-photos",
    });

    const result = try withTaskDataDir(allocator, .{
        .object = given,
    }, "/data/user/0/app/files");

    try std.testing.expectEqualStrings("my-photos", result.object.get("databasePath").?.string);
    try std.testing.expectEqualStrings("/data/user/0/app/files", result.object.get(TASK_DATA_DIR_KEY).?.string);
    try std.testing.expect(given.get(TASK_DATA_DIR_KEY) == null);
}

test "withTaskDataDir replaces a data directory already in the data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var given: std.json.ObjectMap = .empty;
    try given.put(allocator, TASK_DATA_DIR_KEY, .{
        .string = "/somewhere/else",
    });

    const result = try withTaskDataDir(allocator, .{
        .object = given,
    }, "/data/user/0/app/files");

    try std.testing.expectEqualStrings("/data/user/0/app/files", result.object.get(TASK_DATA_DIR_KEY).?.string);
}

test "withTaskDataDir makes an object holding the data directory of no data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try withTaskDataDir(arena.allocator(), .null, "/data/user/0/app/files");

    try std.testing.expectEqual(@as(usize, 1), result.object.count());
    try std.testing.expectEqualStrings("/data/user/0/app/files", result.object.get(TASK_DATA_DIR_KEY).?.string);
}

test "withTaskDataDir returns data that is not an object as it is" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try withTaskDataDir(arena.allocator(), .{
        .string = "a name",
    }, "/data/user/0/app/files");

    try std.testing.expectEqualStrings("a name", result.string);
}

test "taskDatabaseBaseDir is the dbs directory in the data directory in the task's data when PHOTOSPHERE_DATA_DIR is not set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var environment = std.process.Environ.Map.init(allocator);
    const previous = node_utils.process_env.getEnvironMap();
    node_utils.process_env.setEnvironMap(&environment);
    defer node_utils.process_env.setEnvironMap(previous);

    const data = try withTaskDataDir(allocator, .null, "/data/user/0/app/files");

    try std.testing.expectEqualStrings(try std.fs.path.join(arena.allocator(), &.{ "/data/user/0/app/files", "dbs" }), try taskDatabaseBaseDir(allocator, data));
}

test "taskDatabaseBaseDir is the dbs directory in the directory PHOTOSPHERE_DATA_DIR names when it is set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var environment = std.process.Environ.Map.init(allocator);
    try environment.put("PHOTOSPHERE_DATA_DIR", "/tmp/scenario-7/files");
    const previous = node_utils.process_env.getEnvironMap();
    node_utils.process_env.setEnvironMap(&environment);
    defer node_utils.process_env.setEnvironMap(previous);

    const data = try withTaskDataDir(allocator, .null, "/data/user/0/app/files");

    try std.testing.expectEqualStrings(try std.fs.path.join(arena.allocator(), &.{ "/tmp/scenario-7/files", "dbs" }), try taskDatabaseBaseDir(allocator, data));
}

test "taskDatabaseBaseDir is the working directory, an empty base directory, for data with no data directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var environment = std.process.Environ.Map.init(allocator);
    const previous = node_utils.process_env.getEnvironMap();
    node_utils.process_env.setEnvironMap(&environment);
    defer node_utils.process_env.setEnvironMap(previous);
    var given: std.json.ObjectMap = .empty;
    try given.put(allocator, "databasePath", .{
        .string = "my-photos",
    });

    try std.testing.expectEqualStrings("", try taskDatabaseBaseDir(allocator, .{
        .object = given,
    }));
    try std.testing.expectEqualStrings("", try taskDatabaseBaseDir(allocator, .null));
}

