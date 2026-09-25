const std = @import("std");
const utils = @import("utils-zig");
const vault_zig = @import("vault-zig");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const resolveStorageCredentials = node_api.resolve_storage_credentials.resolveStorageCredentials;
const errors = utils.errors;

//
// The environment variables the TypeScript tests clear before and after each test.
//
const credential_variables = [_][]const u8{ "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_REGION", "AWS_ENDPOINT", "PSI_ENCRYPTION_KEY", "GOOGLE_API_KEY" };

//
// Prepares a test: installs the environment, clears the credential variables and points the config dir at a new
// directory holding the given databases.toml (empty text means no file, like `getDatabases` returning []).
//
fn setup(allocator: std.mem.Allocator, io: std.Io, databasesToml: []const u8) ![]const u8 {
    _ = try helpers.setupEnvironment(io);
    for (credential_variables) |name| {
        try helpers.setEnv(name, null);
    }
    const configDir = try helpers.makeTempDir(allocator, io, "credentials-config");
    try helpers.setEnv("PHOTOSPHERE_CONFIG_DIR", configDir);
    if (databasesToml.len > 0) {
        try helpers.writeFile(io, try std.fmt.allocPrint(allocator, "{s}/databases.toml", .{configDir}), databasesToml);
    }
    return configDir;
}

//
// Stores a secret in the test vault.
//
fn setSecret(allocator: std.mem.Allocator, io: std.Io, name: []const u8, secretType: []const u8, value: []const u8) !void {
    const vault = try vault_zig.get_vault.getVault("plaintext");
    try vault.set(allocator, io, .{ .name = name, .type = secretType, .value = value });
}

//
// Reads one of the TypeScript generated keys of encryption-zig.
//
fn readKey(allocator: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
    return helpers.readFile(allocator, io, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ helpers.KEYS_DIR, name }));
}

test "returns empty credentials for a local path with no database entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try setup(allocator, io, "");
    defer helpers.removeTempDir(io, configDir);

    const result = try resolveStorageCredentials(allocator, io, "/local/db", null, null);

    try std.testing.expect(result.s3Config == null);
    try std.testing.expectEqual(@as(usize, 0), result.encryptionKeyPems.len);
    try std.testing.expect(result.googleApiKey == null);
}

test "does not look up S3 credentials for a non-s3: path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try setup(allocator, io, "[[databases]]\nname = \"db\"\ndescription = \"\"\npath = \"/local/db\"\ns3_key = \"my-s3-secret\"\n");
    defer helpers.removeTempDir(io, configDir);
    try setSecret(allocator, io, "my-s3-secret", "s3-credentials", "not json");

    const result = try resolveStorageCredentials(allocator, io, "/local/db", null, null);

    try std.testing.expect(result.s3Config == null);
}

test "loads S3 credentials from vault for an s3: path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try setup(allocator, io, "[[databases]]\nname = \"db\"\ndescription = \"\"\npath = \"s3:my-bucket:/photos\"\ns3_key = \"s3secret\"\n");
    defer helpers.removeTempDir(io, configDir);
    try setSecret(allocator, io, "s3secret", "s3-credentials", "{\"region\":\"us-west-2\",\"accessKeyId\":\"AKID\",\"secretAccessKey\":\"SECRET\",\"endpoint\":\"https://s3.example.com\"}");

    const result = try resolveStorageCredentials(allocator, io, "s3:my-bucket:/photos", null, null);

    try std.testing.expect(result.s3Config != null);
    try std.testing.expectEqualStrings("us-west-2", result.s3Config.?.region.?);
    try std.testing.expectEqualStrings("AKID", result.s3Config.?.accessKeyId);
    try std.testing.expectEqualStrings("SECRET", result.s3Config.?.secretAccessKey);
    try std.testing.expectEqualStrings("https://s3.example.com", result.s3Config.?.endpoint.?);
}

test "falls back to AWS env vars for s3: path when vault entry is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try setup(allocator, io, "");
    defer helpers.removeTempDir(io, configDir);
    try helpers.setEnv("AWS_ACCESS_KEY_ID", "ENV_AKID");
    try helpers.setEnv("AWS_SECRET_ACCESS_KEY", "ENV_SECRET");
    try helpers.setEnv("AWS_REGION", "eu-central-1");
    defer for (credential_variables) |name| {
        helpers.setEnv(name, null) catch {};
    };

    const result = try resolveStorageCredentials(allocator, io, "s3:my-bucket:/photos", null, null);

    try std.testing.expect(result.s3Config != null);
    try std.testing.expectEqualStrings("ENV_AKID", result.s3Config.?.accessKeyId);
    try std.testing.expectEqualStrings("ENV_SECRET", result.s3Config.?.secretAccessKey);
    try std.testing.expectEqualStrings("eu-central-1", result.s3Config.?.region.?);
}

test "uses explicit s3Key argument to look up S3 credentials when the path is not registered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try setup(allocator, io, "");
    defer helpers.removeTempDir(io, configDir);
    try setSecret(allocator, io, "explicit-s3", "s3-credentials", "{\"region\":\"ap-southeast-2\",\"accessKeyId\":\"EXPLICIT_AKID\",\"secretAccessKey\":\"EXPLICIT_SECRET\"}");

    const result = try resolveStorageCredentials(allocator, io, "s3:other-bucket:/photos", null, "explicit-s3");

    try std.testing.expect(result.s3Config != null);
    try std.testing.expectEqualStrings("EXPLICIT_AKID", result.s3Config.?.accessKeyId);
    try std.testing.expectEqualStrings("ap-southeast-2", result.s3Config.?.region.?);
}

test "explicit s3Key argument takes priority over the databases.json entry s3Key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try setup(allocator, io, "[[databases]]\nname = \"db\"\ndescription = \"\"\npath = \"s3:my-bucket:/photos\"\ns3_key = \"registered-s3\"\n");
    defer helpers.removeTempDir(io, configDir);
    try setSecret(allocator, io, "registered-s3", "s3-credentials", "{\"region\":\"us-east-2\",\"accessKeyId\":\"REGISTERED_AKID\",\"secretAccessKey\":\"REGISTERED_SECRET\"}");
    try setSecret(allocator, io, "explicit-s3-priority", "s3-credentials", "{\"region\":\"us-east-2\",\"accessKeyId\":\"EXPLICIT_AKID\",\"secretAccessKey\":\"EXPLICIT_SECRET\"}");

    const result = try resolveStorageCredentials(allocator, io, "s3:my-bucket:/photos", null, "explicit-s3-priority");

    try std.testing.expectEqualStrings("EXPLICIT_AKID", result.s3Config.?.accessKeyId);
}

test "explicit s3Key argument is ignored for non-s3: paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try setup(allocator, io, "");
    defer helpers.removeTempDir(io, configDir);

    const result = try resolveStorageCredentials(allocator, io, "/local/db", null, "explicit-s3");

    try std.testing.expect(result.s3Config == null);
}

test "vault entry takes priority over AWS env vars for S3 credentials" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try setup(allocator, io, "[[databases]]\nname = \"db\"\ndescription = \"\"\npath = \"s3:my-bucket:/photos\"\ns3_key = \"s3secret-vault\"\n");
    defer helpers.removeTempDir(io, configDir);
    try setSecret(allocator, io, "s3secret-vault", "s3-credentials", "{\"region\":\"us-west-2\",\"accessKeyId\":\"VAULT_AKID\",\"secretAccessKey\":\"VAULT_SECRET\"}");
    try helpers.setEnv("AWS_ACCESS_KEY_ID", "ENV_AKID");
    try helpers.setEnv("AWS_SECRET_ACCESS_KEY", "ENV_SECRET");
    defer for (credential_variables) |name| {
        helpers.setEnv(name, null) catch {};
    };

    const result = try resolveStorageCredentials(allocator, io, "s3:my-bucket:/photos", null, null);

    try std.testing.expectEqualStrings("VAULT_AKID", result.s3Config.?.accessKeyId);
}

test "loads encryption key from vault when database entry has encryptionKey (raw PEM format)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try setup(allocator, io, "[[databases]]\nname = \"db\"\ndescription = \"\"\npath = \"/local/db\"\nencryption_key = \"enc-secret\"\n");
    defer helpers.removeTempDir(io, configDir);
    const privateKeyPem = try readKey(allocator, io, "ts-private.pem");
    try setSecret(allocator, io, "enc-secret", "encryption-key", privateKeyPem);

    const result = try resolveStorageCredentials(allocator, io, "/local/db", null, null);

    try std.testing.expectEqual(@as(usize, 1), result.encryptionKeyPems.len);
    try std.testing.expectEqualStrings(privateKeyPem, result.encryptionKeyPems[0].privateKeyPem);
    try std.testing.expectEqualStrings(try readKey(allocator, io, "ts-public.pem"), result.encryptionKeyPems[0].publicKeyPem);
}

test "throws when database entry encryptionKey is set but vault entry is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try setup(allocator, io, "[[databases]]\nname = \"db\"\ndescription = \"\"\npath = \"/local/db\"\nencryption_key = \"missing-enc\"\n");
    defer helpers.removeTempDir(io, configDir);

    try std.testing.expectError(error.Thrown, resolveStorageCredentials(allocator, io, "/local/db", null, null));
    try std.testing.expectEqualStrings("Encryption key \"missing-enc\" not found in vault", errors.lastErrorMessage());
}

test "resolves encryptionKey param as a vault secret name when it is not a file path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try setup(allocator, io, "");
    defer helpers.removeTempDir(io, configDir);
    const privateKeyPem = try readKey(allocator, io, "ts-private.pem");
    try setSecret(allocator, io, "my-enc-secret", "encryption-key", privateKeyPem);

    const result = try resolveStorageCredentials(allocator, io, "/local/db", "my-enc-secret", null);

    try std.testing.expectEqual(@as(usize, 1), result.encryptionKeyPems.len);
    try std.testing.expectEqualStrings(privateKeyPem, result.encryptionKeyPems[0].privateKeyPem);
}

test "resolves encryptionKey param as a file path when the file exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try setup(allocator, io, "");
    defer helpers.removeTempDir(io, configDir);
    const keyPath = helpers.KEYS_DIR ++ "/ts2-private.pem";

    const result = try resolveStorageCredentials(allocator, io, "/local/db", keyPath, null);

    try std.testing.expectEqual(@as(usize, 1), result.encryptionKeyPems.len);
    try std.testing.expectEqualStrings(try readKey(allocator, io, "ts2-private.pem"), result.encryptionKeyPems[0].privateKeyPem);
    try std.testing.expectEqualStrings(try readKey(allocator, io, "ts2-public.pem"), result.encryptionKeyPems[0].publicKeyPem);
}

test "encryptionKey param takes priority over database entry encryptionKey" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try setup(allocator, io, "[[databases]]\nname = \"db\"\ndescription = \"\"\npath = \"/local/db\"\nencryption_key = \"entry-enc-missing\"\n");
    defer helpers.removeTempDir(io, configDir);
    const privateKeyPem = try readKey(allocator, io, "ts2-private.pem");
    try setSecret(allocator, io, "param-enc", "encryption-key", privateKeyPem);

    const result = try resolveStorageCredentials(allocator, io, "/local/db", "param-enc", null);

    try std.testing.expectEqualStrings(privateKeyPem, result.encryptionKeyPems[0].privateKeyPem);
}

test "loads encryption key from PSI_ENCRYPTION_KEY env var (vault secret name) when no other source set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try setup(allocator, io, "");
    defer helpers.removeTempDir(io, configDir);
    const privateKeyPem = try readKey(allocator, io, "ts-private.pem");
    try setSecret(allocator, io, "env-enc-secret", "encryption-key", privateKeyPem);
    try helpers.setEnv("PSI_ENCRYPTION_KEY", "env-enc-secret");
    defer for (credential_variables) |name| {
        helpers.setEnv(name, null) catch {};
    };

    const result = try resolveStorageCredentials(allocator, io, "/local/db", null, null);

    try std.testing.expectEqual(@as(usize, 1), result.encryptionKeyPems.len);
    try std.testing.expectEqualStrings(privateKeyPem, result.encryptionKeyPems[0].privateKeyPem);
}

test "loads geocoding key from vault when database entry has geocodingKey" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try setup(allocator, io, "[[databases]]\nname = \"db\"\ndescription = \"\"\npath = \"/local/db\"\ngeocoding_key = \"geo-secret\"\n");
    defer helpers.removeTempDir(io, configDir);
    try setSecret(allocator, io, "geo-secret", "api-key", "geo-api-key-123");

    const result = try resolveStorageCredentials(allocator, io, "/local/db", null, null);

    try std.testing.expectEqualStrings("geo-api-key-123", result.googleApiKey.?);
}

test "falls back to GOOGLE_API_KEY env var when geocoding vault entry is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try setup(allocator, io, "");
    defer helpers.removeTempDir(io, configDir);
    try helpers.setEnv("GOOGLE_API_KEY", "env-geo-key");
    defer for (credential_variables) |name| {
        helpers.setEnv(name, null) catch {};
    };

    const result = try resolveStorageCredentials(allocator, io, "/local/db", null, null);

    try std.testing.expectEqualStrings("env-geo-key", result.googleApiKey.?);
}

test "vault geocoding entry takes priority over GOOGLE_API_KEY env var" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try setup(allocator, io, "[[databases]]\nname = \"db\"\ndescription = \"\"\npath = \"/local/db\"\ngeocoding_key = \"geo-secret-priority\"\n");
    defer helpers.removeTempDir(io, configDir);
    try setSecret(allocator, io, "geo-secret-priority", "api-key", "vault-geo-key");
    try helpers.setEnv("GOOGLE_API_KEY", "env-geo-key");
    defer for (credential_variables) |name| {
        helpers.setEnv(name, null) catch {};
    };

    const result = try resolveStorageCredentials(allocator, io, "/local/db", null, null);

    try std.testing.expectEqualStrings("vault-geo-key", result.googleApiKey.?);
}

test "throws when encryptionKey value is neither a file nor a vault secret" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try setup(allocator, io, "");
    defer helpers.removeTempDir(io, configDir);

    try std.testing.expectError(error.Thrown, resolveStorageCredentials(allocator, io, "/local/db", "nonexistent", null));
    try std.testing.expectEqualStrings("Encryption key \"nonexistent\" (via -k flag) is neither a file path nor a vault secret name", errors.lastErrorMessage());
}

test "s3Config has undefined endpoint when not provided in vault value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try setup(allocator, io, "[[databases]]\nname = \"db\"\ndescription = \"\"\npath = \"s3:my-bucket:/photos\"\ns3_key = \"s3secret-no-endpoint\"\n");
    defer helpers.removeTempDir(io, configDir);
    try setSecret(allocator, io, "s3secret-no-endpoint", "s3-credentials", "{\"region\":\"us-east-1\",\"accessKeyId\":\"AK\",\"secretAccessKey\":\"SK\"}");

    const result = try resolveStorageCredentials(allocator, io, "s3:my-bucket:/photos", null, null);

    try std.testing.expect(result.s3Config.?.endpoint == null);
}

test "resolves comma-separated encryptionKey param as multiple vault secrets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try setup(allocator, io, "");
    defer helpers.removeTempDir(io, configDir);
    const firstPem = try readKey(allocator, io, "ts-private.pem");
    const secondPem = try readKey(allocator, io, "ts2-private.pem");
    try setSecret(allocator, io, "key1", "encryption-key", firstPem);
    try setSecret(allocator, io, "key2", "encryption-key", secondPem);

    const result = try resolveStorageCredentials(allocator, io, "/local/db", "key1,key2", null);

    try std.testing.expectEqual(@as(usize, 2), result.encryptionKeyPems.len);
    try std.testing.expectEqualStrings(firstPem, result.encryptionKeyPems[0].privateKeyPem);
    try std.testing.expectEqualStrings(secondPem, result.encryptionKeyPems[1].privateKeyPem);
}

test "resolves comma-separated encryptionKey param with whitespace trimming" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try setup(allocator, io, "");
    defer helpers.removeTempDir(io, configDir);
    const firstPem = try readKey(allocator, io, "ts-private.pem");
    const secondPem = try readKey(allocator, io, "ts2-private.pem");
    try setSecret(allocator, io, "key-a", "encryption-key", firstPem);
    try setSecret(allocator, io, "key-b", "encryption-key", secondPem);

    const result = try resolveStorageCredentials(allocator, io, "/local/db", " key-a , key-b ", null);

    try std.testing.expectEqual(@as(usize, 2), result.encryptionKeyPems.len);
    try std.testing.expectEqualStrings(firstPem, result.encryptionKeyPems[0].privateKeyPem);
    try std.testing.expectEqualStrings(secondPem, result.encryptionKeyPems[1].privateKeyPem);
}

test "geocoding vault entry stored as raw string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try setup(allocator, io, "[[databases]]\nname = \"db\"\ndescription = \"\"\npath = \"/local/db\"\ngeocoding_key = \"geo-secret-raw\"\n");
    defer helpers.removeTempDir(io, configDir);
    try setSecret(allocator, io, "geo-secret-raw", "api-key", "geo-key-456");

    const result = try resolveStorageCredentials(allocator, io, "/local/db", null, null);

    try std.testing.expectEqualStrings("geo-key-456", result.googleApiKey.?);
}

test "parseEncryptionKeyFromVaultValue derives the public key PEM like node:crypto" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const pem = try node_api.resolve_storage_credentials.parseEncryptionKeyFromVaultValue(allocator, try readKey(allocator, io, "ts-private.pem"));
    try std.testing.expectEqualStrings(try readKey(allocator, io, "ts-public.pem"), pem.publicKeyPem);
}
