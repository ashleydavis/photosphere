const std = @import("std");
const api = @import("api-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const test_environment = @import("test-environment.zig");
const string_lists = @import("string-lists.zig");
const MAX_IMPORT_RECORD_ENTRIES = api.import_record.MAX_IMPORT_RECORD_ENTRIES;
const IImportRecordEntry = api.import_record.IImportRecordEntry;
const ImportSource = api.import_record.ImportSource;
const getImportRecordPath = node_api.database_cache_dir.getImportRecordPath;
const loadImportRecord = node_api.import_record_storage.loadImportRecord;
const recordImports = node_api.import_record_storage.recordImports;

//
// One import, with everything filled in.
//
fn makeEntry(allocator: std.mem.Allocator, logicalPath: []const u8, source: ImportSource) !IImportRecordEntry {
    return .{
        .assetId = try std.fmt.allocPrint(allocator, "asset-{s}", .{logicalPath}),
        .logicalPath = logicalPath,
        .outcome = .imported,
        .importedAt = "2026-01-01T00:00:00.000Z",
        .source = source,
    };
}

//
// What each test works in (TypeScript: the beforeEach of the describe block).
//
const RecordTest = struct {
    // Holds the test's allocations.
    arena: std.heap.ArenaAllocator,

    // The directory the test's files live in.
    runRoot: []const u8,

    // The database the record is kept for.
    databasePath: []const u8,

    //
    // Every test points the cache directory at one of its own, so the record is written to a real
    // filesystem without any of them reaching the developer's real record or each other's.
    //
    fn init(self: *RecordTest) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const allocator = self.arena.allocator();
        const io = std.testing.io;
        _ = try test_environment.setupEnvironment(io);
        self.runRoot = try temp_dirs.makeTempDir(allocator, io, "import-record-test");
        try test_environment.setEnv("PHOTOSPHERE_CACHE_DIR", try std.fmt.allocPrint(allocator, "{s}/cache", .{self.runRoot}));
        self.databasePath = try std.fmt.allocPrint(allocator, "{s}/photos", .{self.runRoot});
    }

    //
    // Puts the cache directory back the way it was (TypeScript: the afterEach).
    //
    fn deinit(self: *RecordTest) void {
        test_environment.setEnv("PHOTOSPHERE_CACHE_DIR", null) catch {};
        temp_dirs.removeTempDir(std.testing.io, self.runRoot);
        self.arena.deinit();
    }
};

test "a database that has imported nothing reads as empty" {
    var context: RecordTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();

    const record = try loadImportRecord(allocator, std.testing.io, context.databasePath);

    try std.testing.expectEqual(@as(usize, 0), record.entries.len);
    try std.testing.expectEqual(false, record.truncated);
}

test "what was recorded is what comes back" {
    var context: RecordTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;

    recordImports(allocator, io, context.databasePath, &.{
        try makeEntry(allocator, "one", .manual),
        try makeEntry(allocator, "two", .automatic),
    });

    const record = try loadImportRecord(allocator, io, context.databasePath);
    try std.testing.expectEqual(@as(usize, 2), record.entries.len);
    try std.testing.expectEqualStrings("two", record.entries[0].logicalPath);
    try std.testing.expectEqualStrings("one", record.entries[1].logicalPath);
    try std.testing.expectEqual(ImportSource.automatic, record.entries[0].source);
    try std.testing.expectEqual(ImportSource.manual, record.entries[1].source);
}

test "a later import is added to what was already there" {
    var context: RecordTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;

    recordImports(allocator, io, context.databasePath, &.{try makeEntry(allocator, "one", .manual)});
    recordImports(allocator, io, context.databasePath, &.{try makeEntry(allocator, "two", .manual)});

    const record = try loadImportRecord(allocator, io, context.databasePath);
    try std.testing.expectEqual(@as(usize, 2), record.entries.len);
    try std.testing.expectEqualStrings("two", record.entries[0].logicalPath);
    try std.testing.expectEqualStrings("one", record.entries[1].logicalPath);
}

test "it is written to the local path and nowhere else" {
    var context: RecordTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;

    recordImports(allocator, io, context.databasePath, &.{try makeEntry(allocator, "one", .manual)});

    // The location is the whole point of this file: a local path derived from the database path,
    // not a path inside the database, so nothing that copies the database can carry it.
    const written = try test_files.readFile(allocator, io, try getImportRecordPath(allocator, context.databasePath));
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, written, .{});
    try std.testing.expectEqualStrings("one", parsed.object.get("entries").?.array.items[0].object.get("logicalPath").?.string);
}

test "the record is created outside the database, which is left untouched" {
    var context: RecordTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;
    try std.Io.Dir.cwd().createDirPath(io, context.databasePath);

    recordImports(allocator, io, context.databasePath, &.{try makeEntry(allocator, "one", .manual)});

    // Nothing may appear inside the database. Being outside it is what stops the record
    // travelling by sync, replication or consolidation.
    var databaseDir = try std.Io.Dir.cwd().openDir(io, context.databasePath, .{ .iterate = true });
    defer databaseDir.close(io);
    var entries = databaseDir.iterate();
    try std.testing.expect(try entries.next(io) == null);
    try std.testing.expect(!std.mem.startsWith(u8, try getImportRecordPath(allocator, context.databasePath), context.databasePath));
}

test "the cache directory is made when it is not there yet" {
    var context: RecordTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;

    // Nothing creates this directory ahead of the first import, so the first write has to.
    const recordDir = std.fs.path.dirname(try getImportRecordPath(allocator, context.databasePath)).?;
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, recordDir, .{}));

    recordImports(allocator, io, context.databasePath, &.{try makeEntry(allocator, "one", .manual)});

    try std.testing.expectEqual(std.Io.File.Kind.directory, (try std.Io.Dir.cwd().statFile(io, recordDir, .{})).kind);
}

test "recording nothing does not write" {
    var context: RecordTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;

    recordImports(allocator, io, context.databasePath, &.{});

    try std.testing.expect(!test_files.fileExists(io, try getImportRecordPath(allocator, context.databasePath)));
}

test "a record that is not JSON reads as empty rather than throwing" {
    var context: RecordTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;
    try test_files.writeFile(io, try getImportRecordPath(allocator, context.databasePath), "this is not a record");

    const record = try loadImportRecord(allocator, io, context.databasePath);

    try std.testing.expectEqual(@as(usize, 0), record.entries.len);
}

test "JSON that is not a record reads as empty rather than throwing" {
    var context: RecordTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;
    try test_files.writeFile(io, try getImportRecordPath(allocator, context.databasePath), "{\"somethingElse\":true}");

    const record = try loadImportRecord(allocator, io, context.databasePath);

    try std.testing.expectEqual(@as(usize, 0), record.entries.len);
}

test "a record that cannot be read reads as empty rather than throwing" {
    var context: RecordTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;
    // A directory where the file should be: reading it fails the way an unreadable file does.
    // This is a note about what happened, not the photos. It is not worth refusing to open a
    // database over.
    try std.Io.Dir.cwd().createDirPath(io, try getImportRecordPath(allocator, context.databasePath));

    const record = try loadImportRecord(allocator, io, context.databasePath);

    try std.testing.expectEqual(@as(usize, 0), record.entries.len);
    try std.testing.expectEqual(false, record.truncated);
}

test "a record that cannot be written does not fail the import" {
    var context: RecordTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;
    // The cache root is a file, so the directory the record needs cannot be created.
    const blockedDir = try temp_dirs.makeTempDir(allocator, io, "import-record-blocked");
    defer temp_dirs.removeTempDir(io, blockedDir);
    const blockedRoot = try std.fmt.allocPrint(allocator, "{s}/cache", .{blockedDir});
    try test_files.writeFile(io, blockedRoot, "not a directory");
    try test_environment.setEnv("PHOTOSPHERE_CACHE_DIR", blockedRoot);

    // The photos are already in the database by this point. Losing the note about them must not
    // turn a successful import into a failed one. (Zig: recordImports returns nothing, so it cannot fail.)
    recordImports(allocator, io, context.databasePath, &.{try makeEntry(allocator, "one", .manual)});

    try std.testing.expect(!test_files.fileExists(io, try getImportRecordPath(allocator, context.databasePath)));
}

test "the record stays capped across many imports" {
    var context: RecordTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;

    var batch: usize = 0;
    while (batch < 3) : (batch += 1) {
        const entries = try allocator.alloc(IImportRecordEntry, 400);
        for (entries, 0..) |*entry, index| {
            entry.* = try makeEntry(allocator, try std.fmt.allocPrint(allocator, "batch-{d}-file-{d}", .{ batch, index }), .manual);
        }
        recordImports(allocator, io, context.databasePath, entries);
    }

    const record = try loadImportRecord(allocator, io, context.databasePath);
    try std.testing.expectEqual(@as(usize, MAX_IMPORT_RECORD_ENTRIES), record.entries.len);
    try std.testing.expectEqual(true, record.truncated);
    // The newest survived, which is the half of the cap that matters.
    try std.testing.expectEqualStrings("batch-2-file-399", record.entries[0].logicalPath);
}

//
// One of the concurrent writers of the test below.
//
fn recordOneWriter(databasePath: []const u8, index: usize) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const logicalPath = std.fmt.allocPrint(allocator, "writer-{d}", .{index}) catch {
        return;
    };
    const entry = makeEntry(allocator, logicalPath, .manual) catch {
        return;
    };
    recordImports(allocator, std.testing.io, databasePath, &.{entry});
}

test "writers into one database at the same time all survive" {
    var context: RecordTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;

    // The CLI and the desktop app can import into the same database at once. A plain
    // read-modify-write loses all but the last of these, because each reads the same record
    // before any of them has written.
    const writerCount = 8;
    var threads: [writerCount]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, recordOneWriter, .{ context.databasePath, index });
    }
    for (threads) |thread| {
        thread.join();
    }

    const record = try loadImportRecord(allocator, io, context.databasePath);
    const recorded = try allocator.alloc([]const u8, record.entries.len);
    for (record.entries, 0..) |entry, index| {
        recorded[index] = entry.logicalPath;
    }
    string_lists.sortStrings(recorded);
    try std.testing.expectEqual(@as(usize, writerCount), recorded.len);
    for (recorded, 0..) |logicalPath, index| {
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "writer-{d}", .{index}), logicalPath);
    }
}
