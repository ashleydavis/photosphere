const std = @import("std");
const utils = @import("utils-zig");
const vault_zig = @import("vault-zig");
const encryption = @import("encryption-zig");
const index = @import("index.zig");

//
// Names used from other files (the equivalent of the TypeScript imports).
//
const getVault = vault_zig.get_vault.getVault;
const getDefaultVaultType = vault_zig.get_vault.getDefaultVaultType;
const createPrivateKey = encryption.node_crypto.createPrivateKey;
const createPublicKeyFromPrivateKey = encryption.node_crypto.createPublicKeyFromPrivateKey;
const exportPublicKeyToPem = encryption.key_utils.exportPublicKeyToPem;
const ISecretSharePayload = index.ISecretSharePayload;
const IShareDatabaseConfig = index.IShareDatabaseConfig;
const IDatabaseSharePayload = index.IDatabaseSharePayload;
const IShareS3Credentials = index.IShareS3Credentials;
const IShareEncryptionKey = index.IShareEncryptionKey;
const IShareGeocodingKey = index.IShareGeocodingKey;
const errors = utils.errors;

//
// Reads a text field of the parsed S3 credentials (`parsed.region` and the like). A field that is absent or not text
// is thrown as an error naming the secret and the field (TypeScript would send it on as undefined).
//
fn s3CredentialField(parsed: std.json.Value, secretName: []const u8, field: []const u8) ![]const u8 {
    if (parsed == .object) {
        if (parsed.object.get(field)) |value| {
            if (value == .string) {
                return value.string;
            }
        }
    }
    return errors.throwError("The S3 credentials \"{s}\" have no \"{s}\" text field.", .{ secretName, field });
}

//
// Reads the optional endpoint of the parsed S3 credentials (`parsed.endpoint`): null when it is absent, an error when
// it is there but not text.
//
fn s3CredentialEndpoint(parsed: std.json.Value, secretName: []const u8) !?[]const u8 {
    if (parsed != .object or parsed.object.get("endpoint") == null) {
        return null;
    }
    return try s3CredentialField(parsed, secretName, "endpoint");
}

//
// Builds a database share payload by reading the vault to resolve all
// secret references on the given database config into full credential objects.
//
pub fn resolveDatabaseSharePayload(allocator: std.mem.Allocator, io: std.Io, entry: IShareDatabaseConfig) !IDatabaseSharePayload {
    const vault = try getVault(getDefaultVaultType());

    var s3Credentials: ?IShareS3Credentials = null;
    if (entry.s3Key != null and entry.s3Key.?.len > 0) {
        if (try vault.get(allocator, io, entry.s3Key.?)) |secret| {
            const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, secret.value, .{});
            s3Credentials = .{
                .name = entry.s3Key.?,
                .region = try s3CredentialField(parsed, entry.s3Key.?, "region"),
                .accessKeyId = try s3CredentialField(parsed, entry.s3Key.?, "accessKeyId"),
                .secretAccessKey = try s3CredentialField(parsed, entry.s3Key.?, "secretAccessKey"),
                .endpoint = try s3CredentialEndpoint(parsed, entry.s3Key.?),
            };
        }
    }

    var encryptionKey: ?IShareEncryptionKey = null;
    if (entry.encryptionKey != null and entry.encryptionKey.?.len > 0) {
        if (try vault.get(allocator, io, entry.encryptionKey.?)) |secret| {
            const privateKeyPem = secret.value;
            const publicKeyPem = try exportPublicKeyToPem(allocator, createPublicKeyFromPrivateKey(try createPrivateKey(allocator, secret.value)));
            encryptionKey = .{
                .name = entry.encryptionKey.?,
                .privateKeyPem = privateKeyPem,
                .publicKeyPem = publicKeyPem,
            };
        }
    }

    var geocodingKey: ?IShareGeocodingKey = null;
    if (entry.geocodingKey != null and entry.geocodingKey.?.len > 0) {
        if (try vault.get(allocator, io, entry.geocodingKey.?)) |secret| {
            geocodingKey = .{
                .name = entry.geocodingKey.?,
                .apiKey = secret.value,
            };
        }
    }

    return .{
        .type = "database",
        .name = entry.name,
        .description = entry.description,
        .path = entry.path,
        .origin = entry.origin,
        .s3Credentials = s3Credentials,
        .encryptionKey = encryptionKey,
        .geocodingKey = geocodingKey,
    };
}

//
// Builds a secret share payload by reading a vault entry by name
// and wrapping it in the share payload format.
//
pub fn resolveSecretSharePayload(allocator: std.mem.Allocator, io: std.Io, secretName: []const u8) !ISecretSharePayload {
    const vault = try getVault(getDefaultVaultType());
    const secret = try vault.get(allocator, io, secretName) orelse {
        return errors.throwError("Secret \"{s}\" not found in vault.", .{secretName});
    };

    return .{
        .type = "secret",
        .name = secretName,
        .secretType = secret.type,
        .value = secret.value,
    };
}
