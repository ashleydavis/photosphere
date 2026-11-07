const std = @import("std");
const cli = @import("cli-zig");
const helpers = @import("test-helpers.zig");
const node_utils = @import("node-utils-zig");
const storage_helper = cli.storage_helper;

test "local paths never fetch S3 credentials" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(try storage_helper.fetchS3CredentialsForPath(arena.allocator(), std.testing.io, "/some/local/path") == null);
    try std.testing.expect(try storage_helper.fetchS3CredentialsForPath(arena.allocator(), std.testing.io, "fs:/data") == null);
}

test "createStorageForPath creates file storage for a local path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const tmpDir = try helpers.makeTempDir(allocator, "storage-helper");
    defer std.Io.Dir.cwd().deleteTree(io, tmpDir) catch {};
    const result = try storage_helper.createStorageForPath(allocator, io, tmpDir, null);
    try std.testing.expectEqualStrings("fs", result.type);
    try result.storage.write(allocator, io, "hello.txt", null, "hi");
    try std.testing.expect(try result.storage.fileExists(allocator, io, "hello.txt"));
}

//
// Makes a database at the given directory, as far as the CLI's check for one goes: a `.db` folder holding files.dat.
//
fn makeDatabaseAt(allocator: std.mem.Allocator, io: std.Io, databaseDir: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(allocator, &.{ databaseDir, ".db" }));
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(allocator, &.{ databaseDir, ".db", "files.dat" }),
        .data = "",
    });
}

test "resolveDatabasePath keeps a simple name that names a database in the working directory, before the data directory's" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const dataDir = try helpers.makeTempDir(allocator, "resolve-cwd");
    defer std.Io.Dir.cwd().deleteTree(io, dataDir) catch {};
    // The same name in the working directory and in the data directory: the working directory's is the one opened.
    const name = std.fs.path.basename(dataDir);
    try makeDatabaseAt(allocator, io, name);
    defer std.Io.Dir.cwd().deleteTree(io, name) catch {};
    try makeDatabaseAt(allocator, io, try std.fs.path.join(allocator, &.{ dataDir, "dbs", name }));
    var environment = std.process.Environ.Map.init(allocator);
    try environment.put("PHOTOSPHERE_DATA_DIR", dataDir);
    const previous = node_utils.process_env.getEnvironMap();
    node_utils.process_env.setEnvironMap(&environment);
    defer node_utils.process_env.setEnvironMap(previous);

    try std.testing.expectEqualStrings(name, try storage_helper.resolveDatabasePath(allocator, io, name));
}

test "resolveDatabasePath does not work out the data directory for a simple name the working directory has a database of" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const tmpDir = try helpers.makeTempDir(allocator, "resolve-cwd-only");
    defer std.Io.Dir.cwd().deleteTree(io, tmpDir) catch {};
    const name = std.fs.path.basename(tmpDir);
    try makeDatabaseAt(allocator, io, name);
    defer std.Io.Dir.cwd().deleteTree(io, name) catch {};
    // An environment that holds no home directory and no data directory, so working the data directory out would fail the call.
    var environment = std.process.Environ.Map.init(allocator);
    const previous = node_utils.process_env.getEnvironMap();
    node_utils.process_env.setEnvironMap(&environment);
    defer node_utils.process_env.setEnvironMap(previous);

    try std.testing.expectEqualStrings(name, try storage_helper.resolveDatabasePath(allocator, io, name));
}

test "resolveDatabasePath keeps ., ./x and a relative path with folders, which mean the working directory, even when the data directory has a database there" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const dataDir = try helpers.makeTempDir(allocator, "resolve-multi");
    defer std.Io.Dir.cwd().deleteTree(io, dataDir) catch {};
    try makeDatabaseAt(allocator, io, try std.fs.path.join(allocator, &.{ dataDir, "dbs", "foo", "bar" }));
    try makeDatabaseAt(allocator, io, try std.fs.path.join(allocator, &.{ dataDir, "dbs", "x" }));
    var environment = std.process.Environ.Map.init(allocator);
    try environment.put("PHOTOSPHERE_DATA_DIR", dataDir);
    const previous = node_utils.process_env.getEnvironMap();
    node_utils.process_env.setEnvironMap(&environment);
    defer node_utils.process_env.setEnvironMap(previous);

    try std.testing.expectEqualStrings("foo/bar", try storage_helper.resolveDatabasePath(allocator, io, "foo/bar"));
    try std.testing.expectEqualStrings("./x", try storage_helper.resolveDatabasePath(allocator, io, "./x"));
    try std.testing.expectEqualStrings(".", try storage_helper.resolveDatabasePath(allocator, io, "."));
}

test "resolveDatabasePath opens a database in the dbs directory of the data directory when the working directory has none at the path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const dataDir = try helpers.makeTempDir(allocator, "resolve-data-dir");
    defer std.Io.Dir.cwd().deleteTree(io, dataDir) catch {};
    const name = std.fs.path.basename(dataDir);
    const databaseDir = try std.fs.path.join(allocator, &.{ dataDir, "dbs", name });
    try makeDatabaseAt(allocator, io, databaseDir);
    var environment = std.process.Environ.Map.init(allocator);
    try environment.put("PHOTOSPHERE_DATA_DIR", dataDir);
    const previous = node_utils.process_env.getEnvironMap();
    node_utils.process_env.setEnvironMap(&environment);
    defer node_utils.process_env.setEnvironMap(previous);

    try std.testing.expectEqualStrings(databaseDir, try storage_helper.resolveDatabasePath(allocator, io, name));
}

test "resolveDatabasePath keeps a relative path that names a database in neither place, so a new one is made in the working directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const dataDir = try helpers.makeTempDir(allocator, "resolve-neither");
    defer std.Io.Dir.cwd().deleteTree(io, dataDir) catch {};
    const name = std.fs.path.basename(dataDir);
    var environment = std.process.Environ.Map.init(allocator);
    try environment.put("PHOTOSPHERE_DATA_DIR", dataDir);
    const previous = node_utils.process_env.getEnvironMap();
    node_utils.process_env.setEnvironMap(&environment);
    defer node_utils.process_env.setEnvironMap(previous);

    try std.testing.expectEqualStrings(name, try storage_helper.resolveDatabasePath(allocator, io, name));
}

test "resolveDatabasePath keeps an absolute or s3 path as it is" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var environment = std.process.Environ.Map.init(allocator);
    const previous = node_utils.process_env.getEnvironMap();
    node_utils.process_env.setEnvironMap(&environment);
    defer node_utils.process_env.setEnvironMap(previous);
    const absolutePath = try std.fs.path.join(allocator, &.{ try std.process.currentPathAlloc(io, allocator), "no-such-database" });

    try std.testing.expectEqualStrings(absolutePath, try storage_helper.resolveDatabasePath(allocator, io, absolutePath));
    try std.testing.expectEqualStrings("s3:bucket/photos", try storage_helper.resolveDatabasePath(allocator, io, "s3:bucket/photos"));
}

test "resolveDatabaseOption leaves a --db value that names a database record, and resolves one that names none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const dataDir = try helpers.makeTempDir(allocator, "resolve-option");
    defer std.Io.Dir.cwd().deleteTree(io, dataDir) catch {};
    const configDir = try std.fs.path.join(allocator, &.{ dataDir, "config" });
    try std.Io.Dir.cwd().createDirPath(io, configDir);
    const name = std.fs.path.basename(dataDir);
    const databaseDir = try std.fs.path.join(allocator, &.{ dataDir, "dbs", name });
    try makeDatabaseAt(allocator, io, databaseDir);
    var environment = std.process.Environ.Map.init(allocator);
    try environment.put("PHOTOSPHERE_DATA_DIR", dataDir);
    try environment.put("PHOTOSPHERE_CONFIG_DIR", configDir);
    const previous = node_utils.process_env.getEnvironMap();
    node_utils.process_env.setEnvironMap(&environment);
    defer node_utils.process_env.setEnvironMap(previous);

    // No database record yet: the simple name is found in the data directory's dbs directory.
    try std.testing.expectEqualStrings(databaseDir, try storage_helper.resolveDatabaseOption(allocator, io, name));

    // A database record named the same, in another letter case: the value is left for the command to look the record up by.
    const toml = try std.fmt.allocPrint(allocator, "[[databases]]\nname = \"{s}\"\ndescription = \"\"\npath = \"/elsewhere\"\n", .{name});
    const tomlPath = try std.fs.path.join(allocator, &.{ configDir, "databases.toml" });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = tomlPath,
        .data = toml,
    });
    const upperName = try std.ascii.allocUpperString(allocator, name);
    try std.testing.expectEqualStrings(upperName, try storage_helper.resolveDatabaseOption(allocator, io, upperName));
}
