const std = @import("std");
const api = @import("api-zig");
const utils = @import("utils-zig");
const vault_zig = @import("vault-zig");
const encryption = @import("encryption-zig");
const test_vault = @import("lan-share-test-vault.zig");

const resolveSecretSharePayload = api.lan_share_resolve.resolveSecretSharePayload;
const resolveDatabaseSharePayload = api.lan_share_resolve.resolveDatabaseSharePayload;
const IShareDatabaseConfig = api.lan_share.IShareDatabaseConfig;
const getVault = vault_zig.get_vault.getVault;
const errors = utils.errors;

//
// Generates an RSA private key PEM for the tests that share an encryption key (the TypeScript tests mock
// node:crypto so that a fake PEM passes; Zig derives the public key for real). 2048 bits keeps the tests fast.
//
fn generatePrivateKeyPem(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    return (try encryption.node_crypto.generateKeyPairSync(allocator, io, 2048)).privateKey;
}

//
// The SPKI PEM of the public half of a private key PEM (what resolveDatabaseSharePayload sends as publicKeyPem).
//
fn publicKeyPemOf(allocator: std.mem.Allocator, privateKeyPem: []const u8) ![]const u8 {
    const privateKey = try encryption.node_crypto.createPrivateKey(allocator, privateKeyPem);
    return encryption.key_utils.exportPublicKeyToPem(allocator, encryption.node_crypto.createPublicKeyFromPrivateKey(privateKey));
}

test "resolves database payload with all secrets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    try test_vault.useTestVault();
    defer test_vault.useRealEnvironment();
    try test_vault.clearTestVault(allocator, io);
    const privateKeyPem = try generatePrivateKeyPem(allocator, io);
    const vault = try getVault("plaintext");
    try vault.set(allocator, io, .{
        .name = "abc12345",
        .type = "s3-credentials",
        .value = "{\"region\":\"us-east-1\",\"accessKeyId\":\"AKID\",\"secretAccessKey\":\"SECRET\",\"endpoint\":\"https://s3.example.com\"}",
    });
    try vault.set(allocator, io, .{
        .name = "def67890",
        .type = "encryption-key",
        .value = privateKeyPem,
    });
    try vault.set(allocator, io, .{
        .name = "ghi11111",
        .type = "api-key",
        .value = "geo-key-123",
    });
    const entry: IShareDatabaseConfig = .{
        .name = "my-photos",
        .description = "Family photos",
        .path = "/data/photos",
        .origin = "https://example.com",
        .s3Key = "abc12345",
        .encryptionKey = "def67890",
        .geocodingKey = "ghi11111",
    };

    const payload = try resolveDatabaseSharePayload(allocator, io, entry);

    try std.testing.expectEqualStrings("database", payload.type);
    try std.testing.expectEqualStrings("my-photos", payload.name);
    try std.testing.expectEqualStrings("Family photos", payload.description);
    try std.testing.expectEqualStrings("/data/photos", payload.path);
    try std.testing.expectEqualStrings("https://example.com", payload.origin.?);

    try std.testing.expectEqualStrings("abc12345", payload.s3Credentials.?.name);
    try std.testing.expectEqualStrings("us-east-1", payload.s3Credentials.?.region.?);
    try std.testing.expectEqualStrings("AKID", payload.s3Credentials.?.accessKeyId.?);
    try std.testing.expectEqualStrings("SECRET", payload.s3Credentials.?.secretAccessKey.?);
    try std.testing.expectEqualStrings("https://s3.example.com", payload.s3Credentials.?.endpoint.?);

    try std.testing.expectEqualStrings("def67890", payload.encryptionKey.?.name);
    try std.testing.expectEqualStrings(privateKeyPem, payload.encryptionKey.?.privateKeyPem);
    try std.testing.expectEqualStrings(try publicKeyPemOf(allocator, privateKeyPem), payload.encryptionKey.?.publicKeyPem.?);

    try std.testing.expectEqualStrings("ghi11111", payload.geocodingKey.?.name);
    try std.testing.expectEqualStrings("geo-key-123", payload.geocodingKey.?.apiKey);
}

test "resolves database payload with no secrets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try test_vault.useTestVault();
    defer test_vault.useRealEnvironment();
    const entry: IShareDatabaseConfig = .{
        .name = "simple-db",
        .description = "",
        .path = "/data/simple",
    };

    const payload = try resolveDatabaseSharePayload(allocator, std.testing.io, entry);

    try std.testing.expectEqualStrings("database", payload.type);
    try std.testing.expectEqualStrings("simple-db", payload.name);
    try std.testing.expect(payload.s3Credentials == null);
    try std.testing.expect(payload.encryptionKey == null);
    try std.testing.expect(payload.geocodingKey == null);
}

test "resolves database payload when secret ID exists but vault entry is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    try test_vault.useTestVault();
    defer test_vault.useRealEnvironment();
    try test_vault.clearTestVault(allocator, io);
    const entry: IShareDatabaseConfig = .{
        .name = "orphaned-db",
        .description = "",
        .path = "/data/orphaned",
        .s3Key = "missing123",
    };

    const payload = try resolveDatabaseSharePayload(allocator, io, entry);

    try std.testing.expect(payload.s3Credentials == null);
}

test "derives publicKeyPem from raw-PEM encryption-key value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    try test_vault.useTestVault();
    defer test_vault.useRealEnvironment();
    try test_vault.clearTestVault(allocator, io);
    const privateKeyPem = try generatePrivateKeyPem(allocator, io);
    const vault = try getVault("plaintext");
    try vault.set(allocator, io, .{
        .name = "raw-pem-key",
        .type = "encryption-key",
        .value = privateKeyPem,
    });
    const entry: IShareDatabaseConfig = .{
        .name = "enc-only-db",
        .description = "",
        .path = "/data/enc",
        .encryptionKey = "raw-pem-key",
    };

    const payload = try resolveDatabaseSharePayload(allocator, io, entry);

    try std.testing.expectEqualStrings(privateKeyPem, payload.encryptionKey.?.privateKeyPem);
    try std.testing.expect(std.mem.startsWith(u8, payload.encryptionKey.?.publicKeyPem.?, "-----BEGIN PUBLIC KEY-----\n"));
    try std.testing.expectEqualStrings(try publicKeyPemOf(allocator, privateKeyPem), payload.encryptionKey.?.publicKeyPem.?);
}

//
// TypeScript reads `parsed.region` and sends whatever it is, so credentials stored without a region are shared
// without one (JSON.stringify leaves the undefined field out of the payload).
//
test "S3 credentials without a region are shared without one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    try test_vault.useTestVault();
    defer test_vault.useRealEnvironment();
    try test_vault.clearTestVault(allocator, io);
    const vault = try getVault("plaintext");
    try vault.set(allocator, io, .{
        .name = "no-region",
        .type = "s3-credentials",
        .value = "{\"accessKeyId\":\"AKID\",\"secretAccessKey\":\"SECRET\"}",
    });
    const entry: IShareDatabaseConfig = .{
        .name = "db",
        .description = "",
        .path = "s3:bucket",
        .s3Key = "no-region",
    };

    const payload = try resolveDatabaseSharePayload(allocator, io, entry);
    try std.testing.expect(payload.s3Credentials.?.region == null);
    try std.testing.expectEqualStrings("AKID", payload.s3Credentials.?.accessKeyId.?);
    try std.testing.expectEqualStrings("SECRET", payload.s3Credentials.?.secretAccessKey.?);
    try std.testing.expect(payload.s3Credentials.?.endpoint == null);
}

test "resolves secret share payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    try test_vault.useTestVault();
    defer test_vault.useRealEnvironment();
    const vault = try getVault("plaintext");
    try vault.set(allocator, io, .{
        .name = "abc12345",
        .type = "s3-credentials",
        .value = "{\"region\":\"us-east-1\",\"accessKeyId\":\"AKID\",\"secretAccessKey\":\"SECRET\"}",
    });

    const payload = try resolveSecretSharePayload(allocator, io, "abc12345");

    try std.testing.expectEqualStrings("secret", payload.type);
    try std.testing.expectEqualStrings("s3-credentials", payload.secretType);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, payload.value, .{});
    try std.testing.expectEqualStrings("us-east-1", parsed.object.get("region").?.string);
}

test "resolves secret share payload throws when secret not found" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try test_vault.useTestVault();
    defer test_vault.useRealEnvironment();

    try std.testing.expectError(error.Thrown, resolveSecretSharePayload(arena.allocator(), std.testing.io, "nonexistent"));
    try std.testing.expectEqualStrings("Secret \"nonexistent\" not found in vault.", errors.lastErrorMessage());
}
