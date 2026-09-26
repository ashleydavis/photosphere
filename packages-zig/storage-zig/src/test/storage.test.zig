const std = @import("std");
const storage_zig = @import("storage-zig");
const IStorage = storage_zig.storage.IStorage;

test "IStorage exposes the TypeScript method names" {
    try std.testing.expect(@hasDecl(IStorage, "isEmpty"));
    try std.testing.expect(@hasDecl(IStorage, "listFiles"));
    try std.testing.expect(@hasDecl(IStorage, "listDirs"));
    try std.testing.expect(@hasDecl(IStorage, "fileExists"));
    try std.testing.expect(@hasDecl(IStorage, "dirExists"));
    try std.testing.expect(@hasDecl(IStorage, "info"));
    try std.testing.expect(@hasDecl(IStorage, "read"));
    try std.testing.expect(@hasDecl(IStorage, "write"));
    try std.testing.expect(@hasDecl(IStorage, "readStream"));
    try std.testing.expect(@hasDecl(IStorage, "writeStream"));
    try std.testing.expect(@hasDecl(IStorage, "deleteFile"));
    try std.testing.expect(@hasDecl(IStorage, "deleteDir"));
    try std.testing.expect(@hasDecl(IStorage, "copyTo"));
}
