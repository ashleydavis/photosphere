const std = @import("std");
const cli = @import("cli-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");

test "the replicate and verify options default to undefined" {
    const replicateOptions: cli.replicate.IReplicateCommandOptions = .{};
    try std.testing.expect(replicateOptions.dest == null);
    try std.testing.expect(replicateOptions.base.db == null);
    const verifyOptions: cli.verify.IVerifyCommandOptions = .{};
    try std.testing.expect(verifyOptions.full == null);
    try std.testing.expect(verifyOptions.base.yes == null);
}

//
// A verification that found nothing wrong.
//
fn cleanResult() cli.verify.IVerifyResult {
    return .{
        .totalImports = 0,
        .totalFiles = 6758,
        .totalSize = 9_000_000_000,
        .numUnmodified = 6758,
        .numFailures = 0,
        .modified = &.{},
        .new = &.{},
        .removed = &.{},
        .filesProcessed = 6758,
        .nodesProcessed = 13515,
        .recordMismatches = &.{},
    };
}

//
// A reading of the database's own files that found nothing wrong.
//
fn cleanDatabaseFiles() cli.verify.IDatabaseFileVerifyResult {
    return .{
        .totalFiles = 208,
        .totalSize = 21_000_000,
        .validFiles = 208,
        .invalidFiles = &.{},
        .errors = &.{},
    };
}

test "a database with nothing wrong has no problems" {
    try std.testing.expect(!cli.verify.verifyFoundProblems(cleanResult(), cleanDatabaseFiles()));
}

test "a database whose files were never read has no problems of its own" {
    try std.testing.expect(!cli.verify.verifyFoundProblems(cleanResult(), null));
}

//
// The one this was written for. Every file was present and hashed correctly, and 180 assets had
// no database record: the sync pushes files first and the records that describe them after, so
// stopping it part way leaves exactly this. The command printed it and exited 0.
//
test "an asset whose record is missing is a problem" {
    var result = cleanResult();
    result.recordMismatches = &.{"asset/f1e7336b-6bbc-4a19-aacd-c1b6887bf542"};
    try std.testing.expect(cli.verify.verifyFoundProblems(result, cleanDatabaseFiles()));
}

test "a file whose bytes changed is a problem" {
    var result = cleanResult();
    result.modified = &.{"asset/one"};
    try std.testing.expect(cli.verify.verifyFoundProblems(result, cleanDatabaseFiles()));
}

test "a file that could not be read is a problem" {
    var result = cleanResult();
    result.numFailures = 1;
    try std.testing.expect(cli.verify.verifyFoundProblems(result, cleanDatabaseFiles()));
}

test "a file the tree does not know about is a problem" {
    var result = cleanResult();
    result.new = &.{"asset/two"};
    try std.testing.expect(cli.verify.verifyFoundProblems(result, cleanDatabaseFiles()));
}

test "a file the tree expects and cannot find is a problem" {
    var result = cleanResult();
    result.removed = &.{"asset/three"};
    try std.testing.expect(cli.verify.verifyFoundProblems(result, cleanDatabaseFiles()));
}

test "a corrupt database file is a problem" {
    var databaseFiles = cleanDatabaseFiles();
    databaseFiles.invalidFiles = &.{".db/files.dat"};
    try std.testing.expect(cli.verify.verifyFoundProblems(cleanResult(), databaseFiles));
}

test "the add options default to undefined" {
    const addOptions: cli.add.IAddCommandOptions = .{};
    try std.testing.expect(addOptions.dryRun == null);
    try std.testing.expect(addOptions.watch == null);
    try std.testing.expect(addOptions.cleanup == null);
    try std.testing.expect(addOptions.base.db == null);
}

test "watchSettings watches the named folders, recursing into them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const settings = try cli.add.watchSettings(allocator, std.testing.io, &.{ "/photos", "/more" });
    try std.testing.expect(settings.enabled);
    try std.testing.expectEqual(@as(usize, 2), settings.sources.len);
    try std.testing.expectEqualStrings("/photos", settings.sources[0].folder.path);
    try std.testing.expect(settings.sources[0].folder.recurse);
    try std.testing.expectEqualStrings("/more", settings.sources[1].folder.path);
    try std.testing.expect(settings.sources[1].folder.recurse);
}

test "watchSettings watches this operating system's photo folders when no folder is named" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const expected = try node_utils.photo_folders.getDefaultPhotoFolders(allocator, std.testing.io);
    const settings = try cli.add.watchSettings(allocator, std.testing.io, &.{});
    try std.testing.expect(settings.enabled);
    try std.testing.expectEqual(expected.len, settings.sources.len);
    for (expected, settings.sources) |folderPath, source| {
        try std.testing.expectEqualStrings(folderPath, source.folder.path);
        try std.testing.expect(source.folder.recurse);
    }
}

test "the add progress line pads the counts and shows only the counts that are not zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    cli.picocolors.setColorSupportOverride(false);
    defer cli.picocolors.setColorSupportOverride(null);
    var options: cli.add.IAddCommandOptions = .{};
    var progress: cli.add.ProgressState = .{
        .options = &options,
    };
    const added: node_api.media_file_database.IAddSummary = .{
        .filesAdded = 3,
    };
    try std.testing.expectEqualStrings("Added:    3 | Abort with Ctrl-C. It is safe to abort and resume later.", try progress.buildProgressMessage(allocator, null, &added));
    try std.testing.expectEqualStrings("Added:    3 | Abort with Ctrl-C. It is safe to abort and resume later.", try progress.buildProgressMessage(allocator, "", &added));
    const everything: node_api.media_file_database.IAddSummary = .{
        .filesAdded = 12345,
        .filesAlreadyAdded = 2,
        .filesIgnored = 3,
        .filesFailed = 4,
    };
    try std.testing.expectEqualStrings(
        "Added: 12345 | Existing:    2 | Ignored:    3 | Failed:    4 | Scanning /photos | Abort with Ctrl-C. It is safe to abort and resume later.",
        try progress.buildProgressMessage(allocator, "/photos", &everything),
    );
    options.dryRun = true;
    try std.testing.expectEqualStrings("Would add:    3 | DRY RUN | Abort with Ctrl-C. It is safe to abort and resume later.", try progress.buildProgressMessage(allocator, null, &added));
}
