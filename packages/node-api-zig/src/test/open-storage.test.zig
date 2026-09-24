const std = @import("std");
const vault_zig = @import("vault-zig");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const openStorage = node_api.open_storage.openStorage;

//
// Installs the environment and points the config dir at a new directory with the given databases.toml.
//
fn setup(allocator: std.mem.Allocator, io: std.Io, databasesToml: []const u8) ![]const u8 {
    _ = try helpers.setupEnvironment(io);
    const configDir = try helpers.makeTempDir(allocator, io, "open-storage-config");
    try helpers.setEnv("PHOTOSPHERE_CONFIG_DIR", configDir);
    if (databasesToml.len > 0) {
        try helpers.writeFile(io, try std.fmt.allocPrint(allocator, "{s}/databases.toml", .{configDir}), databasesToml);
    }
    return configDir;
}

test "forwards databasePath, encryptionKey, and s3Key to resolveStorageCredentials" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try setup(allocator, io, "");
    defer helpers.removeTempDir(io, configDir);
    const vault = try vault_zig.get_vault.getVault("plaintext");
    try vault.set(allocator, io, .{ .name = "open-storage-s3", .type = "s3-credentials", .value = "{\"region\":\"us-east-1\",\"accessKeyId\":\"AKID\",\"secretAccessKey\":\"SECRET\"}" });

    const result = try openStorage(allocator, io, "s3:bucket:/prefix", helpers.KEYS_DIR ++ "/ts-private.pem", "open-storage-s3");

    try std.testing.expectEqualStrings("AKID", result.s3Config.?.accessKeyId);
    try std.testing.expectEqual(@as(usize, 1), result.encryptionKeyPems.len);
}

test "passes the resolved encryption PEMs to loadEncryptionKeysFromPem" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try setup(allocator, io, "");
    defer helpers.removeTempDir(io, configDir);
    const dir = try helpers.makeTempDir(allocator, io, "open-storage-encrypted");
    defer helpers.removeTempDir(io, dir);

    const result = try openStorage(allocator, io, dir, helpers.KEYS_DIR ++ "/ts-private.pem", null);

    try std.testing.expect(result.storageOptions.encryptionPublicKey != null);
    try std.testing.expect(result.storageOptions.decryptionKeyMap.?.get("default") != null);

    // The storage encrypts what it writes and the raw storage does not.
    try result.storage.write(allocator, io, "file.txt", null, "secret data");
    const rawData = (try result.rawStorage.read(allocator, io, "file.txt")).?;
    try std.testing.expect(!std.mem.eql(u8, rawData, "secret data"));
    try std.testing.expectEqualStrings("secret data", (try result.storage.read(allocator, io, "file.txt")).?);
}

test "passes the resolved s3Config and storage options into createStorage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try setup(allocator, io, "[[databases]]\nname = \"db\"\ndescription = \"\"\npath = \"s3:bucket/prefix\"\ns3_key = \"open-storage-registered\"\n");
    defer helpers.removeTempDir(io, configDir);
    const vault = try vault_zig.get_vault.getVault("plaintext");
    try vault.set(allocator, io, .{ .name = "open-storage-registered", .type = "s3-credentials", .value = "{\"region\":\"us-east-1\",\"accessKeyId\":\"AKID\",\"secretAccessKey\":\"SECRET\"}" });

    const result = try openStorage(allocator, io, "s3:bucket/prefix", null, null);

    try std.testing.expectEqualStrings("us-east-1", result.s3Config.?.region.?);
    try std.testing.expectEqualStrings("s3:/bucket/prefix", result.storage.location);
}

test "returns storage, rawStorage, encryptionKeyPems, s3Config, storageOptions, and googleApiKey" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const dir = try helpers.makeTempDir(allocator, io, "open-storage-all");
    defer helpers.removeTempDir(io, dir);
    const configDir = try setup(allocator, io, try std.fmt.allocPrint(allocator, "[[databases]]\nname = \"db\"\ndescription = \"\"\npath = \"{s}\"\ngeocoding_key = \"open-storage-geo\"\n", .{dir}));
    defer helpers.removeTempDir(io, configDir);
    const vault = try vault_zig.get_vault.getVault("plaintext");
    try vault.set(allocator, io, .{ .name = "open-storage-geo", .type = "api-key", .value = "google-api-key" });

    const result = try openStorage(allocator, io, dir, null, null);

    try std.testing.expectEqualStrings("google-api-key", result.googleApiKey.?);
    try std.testing.expect(result.s3Config == null);
    try std.testing.expectEqual(@as(usize, 0), result.encryptionKeyPems.len);
    try std.testing.expect(result.storageOptions.encryptionPublicKey == null);
    const expectedLocation = try std.fmt.allocPrint(allocator, "fs:{s}", .{dir});
    try std.testing.expectEqualStrings(expectedLocation, result.storage.location);
    try std.testing.expectEqualStrings(expectedLocation, result.rawStorage.location);
}

test "works without encryptionKey or s3Key arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try setup(allocator, io, "");
    defer helpers.removeTempDir(io, configDir);

    const result = try openStorage(allocator, io, "/some/path", null, null);

    try std.testing.expect(result.s3Config == null);
    try std.testing.expectEqual(@as(usize, 0), result.encryptionKeyPems.len);
}
