const std = @import("std");
const cli = @import("cli-zig");

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
