const std = @import("std");
const utils = @import("utils-zig");
const vault_zig = @import("vault-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const test_environment = @import("test-environment.zig");
const fixture_dirs = @import("fixture-dirs.zig");
const recording_task_context = @import("recording-task-context.zig");
const errors = utils.errors;
const setDatabaseOriginHandler = node_api.set_database_origin_worker.setDatabaseOriginHandler;
const createDatabaseHandler = node_api.create_database_worker.createDatabaseHandler;
const addDatabaseEntry = node_api.databases_config.addDatabaseEntry;
const RecordingTaskContext = recording_task_context.RecordingTaskContext;

//
// Runs the handler for a path and an origin (the key is left out of the data when origin is null).
//
fn run(allocator: std.mem.Allocator, io: std.Io, context: *RecordingTaskContext, databasePath: []const u8, origin: ?[]const u8) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "databasePath", .{ .string = databasePath });
    if (origin) |text| {
        try object.put(allocator, "origin", .{ .string = text });
    }
    return setDatabaseOriginHandler(allocator, io, .{ .object = object }, context.taskContext());
}

//
// Reads the config the database keeps on disk, which is a plain file whether or not the database is encrypted.
//
fn readConfigFile(allocator: std.mem.Allocator, io: std.Io, databaseDir: []const u8) !std.json.ObjectMap {
    const text = try test_files.readFile(allocator, io, try std.fs.path.join(allocator, &.{ databaseDir, ".db", "config.json" }));
    return (try std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{})).object;
}

test "writes the origin into the database's own config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);
    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "1-asset");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(databaseDir).?);

    const output = try run(allocator, io, &context, databaseDir, "s3:my-bucket/photos");

    try std.testing.expect(output == .null);
    const config = try readConfigFile(allocator, io, databaseDir);
    try std.testing.expectEqualStrings("s3:my-bucket/photos", config.get("origin").?.string);
}

test "an absent origin clears it rather than being ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);
    const databaseDir = try temp_dirs.copyTestDatabase(allocator, io, "1-asset");
    defer temp_dirs.removeTempDir(io, std.fs.path.dirname(databaseDir).?);
    _ = try run(allocator, io, &context, databaseDir, "s3:my-bucket/photos");
    try std.testing.expect((try readConfigFile(allocator, io, databaseDir)).get("origin") != null);

    _ = try run(allocator, io, &context, databaseDir, null);

    try std.testing.expect((try readConfigFile(allocator, io, databaseDir)).get("origin") == null);
}

test "the config is written through the raw storage, so an encrypted database stays readable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);

    // An encrypted database: its path is listed with the name of a vault secret that holds the key pair.
    const configDir = try temp_dirs.makeTempDir(allocator, io, "set-origin-config");
    defer temp_dirs.removeTempDir(io, configDir);
    try test_environment.setEnv("PHOTOSPHERE_CONFIG_DIR", configDir);
    const rootDir = try temp_dirs.makeTempDir(allocator, io, "set-origin-encrypted");
    defer temp_dirs.removeTempDir(io, rootDir);
    const databaseDir = try std.fs.path.join(allocator, &.{ rootDir, "encrypted-db" });
    try addDatabaseEntry(allocator, io, .{
        .name = "encrypted-db",
        .description = "",
        .path = databaseDir,
        .encryptionKey = "set-origin-test-key",
    });
    const vault = try vault_zig.get_vault.getVault("plaintext");
    try vault.set(allocator, io, .{
        .name = "set-origin-test-key",
        .type = "encryption-key",
        .value = try test_files.readFile(allocator, io, fixture_dirs.KEYS_DIR ++ "/ts-private.pem"),
    });
    var createData: std.json.ObjectMap = .empty;
    try createData.put(allocator, "databasePath", .{ .string = databaseDir });
    _ = try createDatabaseHandler(allocator, io, .{ .object = createData }, context.taskContext());

    _ = try run(allocator, io, &context, databaseDir, "s3:my-bucket/photos");

    // The sync loop reads this config before it has any encryption key, so writing it through the
    // encrypting storage would leave an origin only a key holder could read, and a background
    // pass would decide the database has nowhere to sync to.
    const config = try readConfigFile(allocator, io, databaseDir);
    try std.testing.expectEqualStrings("s3:my-bucket/photos", config.get("origin").?.string);
}

test "a missing database path is refused rather than writing to nowhere" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);

    try std.testing.expectError(error.Thrown, run(allocator, io, &context, "", "s3:my-bucket/photos"));
    try std.testing.expectEqualStrings("databasePath is required", errors.lastErrorMessage());
}

test "throws when the task data has no database path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);

    try std.testing.expectError(error.Thrown, setDatabaseOriginHandler(allocator, io, .{ .object = .empty }, context.taskContext()));
    try std.testing.expectEqualStrings("databasePath is required", errors.lastErrorMessage());
}

test "throws a descriptive error when the origin is not a string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try test_environment.setupEnvironment(io);
    var context: RecordingTaskContext = undefined;
    try context.init(allocator, null, null);
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "databasePath", .{ .string = "db" });
    try object.put(allocator, "origin", .{ .integer = 5 });

    try std.testing.expectError(error.Thrown, setDatabaseOriginHandler(allocator, io, .{ .object = object }, context.taskContext()));
    try std.testing.expectEqualStrings("The set-database-origin task data is not valid: databasePath and origin must be strings", errors.lastErrorMessage());
}
