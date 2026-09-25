const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const storage_zig = @import("storage-zig");
const encryption = @import("encryption-zig");
const vault_zig = @import("vault-zig");
const databases_config = @import("databases-config.zig");
const errors = utils.errors;
const log = &utils.log.log;
const process_env = node_utils.process_env;
const node_crypto = encryption.node_crypto;
const IS3Credentials = storage_zig.cloud_storage.IS3Credentials;
const IEncryptionKeyPem = encryption.key_utils.IEncryptionKeyPem;
const exportPublicKeyToPem = encryption.key_utils.exportPublicKeyToPem;
const IVault = vault_zig.vault.IVault;
const getVault = vault_zig.get_vault.getVault;
const getDefaultVaultType = vault_zig.get_vault.getDefaultVaultType;
const IDatabaseEntry = databases_config.IDatabaseEntry;

//
// The fully-resolved credentials needed to open a storage instance.
// Returned by resolveStorageCredentials and passed directly to createStorage.
//
pub const IResolvedStorageCredentials = struct {
    //
    // S3 credentials when the database path starts with "s3:". Null for local paths.
    //
    s3Config: ?IS3Credentials = null,

    //
    // PEM key pairs for encryption. Empty when no encryption key is configured.
    //
    encryptionKeyPems: []const IEncryptionKeyPem,

    //
    // Google geocoding API key when configured. Null when not configured.
    //
    googleApiKey: ?[]const u8 = null,
};

//
// Resolves an encryption key PEM pair from a vault secret value.
// The vault stores the private key PEM directly; the public key is derived from it.
//
pub fn parseEncryptionKeyFromVaultValue(allocator: std.mem.Allocator, value: []const u8) !IEncryptionKeyPem {
    const privateKeyObj = try node_crypto.createPrivateKey(allocator, value);
    const publicKeyPem = try exportPublicKeyToPem(allocator, node_crypto.createPublicKeyFromPrivateKey(privateKeyObj));
    return .{ .privateKeyPem = value, .publicKeyPem = publicKeyPem };
}

//
// Equivalent of a JavaScript truthiness test of an optional string (not null and not empty).
// (No TypeScript counterpart.)
//
fn isTruthy(value: ?[]const u8) bool {
    return value != null and value.?.len > 0;
}

//
// Gets a string property of a parsed JSON object (null when it is absent or not a string, like `parsed.key`
// reading undefined). (No TypeScript counterpart.)
//
fn jsonString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse {
        return null;
    };
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

//
// Resolves all storage credentials needed to open a database at the given path.
//
// Priority order:
//   S3:            explicit s3Key param → databases.json entry (s3Key) → AWS_* env vars
//   Encryption:    explicit encryptionKey param → databases.json entry → PSI_ENCRYPTION_KEY env var
//   Geocoding:     databases.json entry (geocodingKey) → GOOGLE_API_KEY env var
//
// The vault is only accessed when a credential source actually requires it.
// S3 lookup is skipped entirely for non-s3: paths.
//
// Callers pass explicit `encryptionKey` and/or `s3Key` when the path is not in databases.json
// (for example the destination of a replicate task) or to override the registered values.
//
pub fn resolveStorageCredentials(
    allocator: std.mem.Allocator,
    io: std.Io,
    databasePath: []const u8,
    encryptionKey: ?[]const u8,
    s3Key: ?[]const u8,
) !IResolvedStorageCredentials {
    const vault = try getVault(getDefaultVaultType());

    const databases = try databases_config.getDatabases(allocator, io);
    var entry: ?IDatabaseEntry = null;
    for (databases) |dbEntry| {
        if (std.mem.eql(u8, dbEntry.path, databasePath)) {
            entry = dbEntry;
            break;
        }
    }

    // --- S3 ---

    var s3Config: ?IS3Credentials = null;

    if (std.mem.startsWith(u8, databasePath, "s3:")) {
        const s3KeyToUse = s3Key orelse if (entry) |dbEntry| dbEntry.s3Key else null;
        if (isTruthy(s3KeyToUse)) {
            const secret = try vault.get(allocator, io, s3KeyToUse.?);
            if (secret) |s3Secret| {
                const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, s3Secret.value, .{}) catch |err| {
                    return errors.throwError("JSON Parse error: {s}", .{@errorName(err)});
                };
                const parsedObject = switch (parsed) {
                    .object => |object| object,
                    else => std.json.ObjectMap.empty,
                };
                s3Config = .{
                    .region = jsonString(parsedObject, "region"),
                    .accessKeyId = jsonString(parsedObject, "accessKeyId") orelse "",
                    .secretAccessKey = jsonString(parsedObject, "secretAccessKey") orelse "",
                    .endpoint = jsonString(parsedObject, "endpoint"),
                };
                log.verbose(try std.fmt.allocPrint(allocator, "S3 credentials: loaded from vault (key \"{s}\")", .{s3KeyToUse.?}));
            }
            else {
                log.verbose(try std.fmt.allocPrint(allocator, "S3 credentials: vault key \"{s}\" not found", .{s3KeyToUse.?}));
            }
        }

        if (s3Config == null and isTruthy(process_env.getEnv("AWS_ACCESS_KEY_ID")) and isTruthy(process_env.getEnv("AWS_SECRET_ACCESS_KEY"))) {
            const region = process_env.getEnv("AWS_REGION");
            s3Config = .{
                .region = if (isTruthy(region)) region.? else "us-east-1",
                .accessKeyId = process_env.getEnv("AWS_ACCESS_KEY_ID").?,
                .secretAccessKey = process_env.getEnv("AWS_SECRET_ACCESS_KEY").?,
                .endpoint = process_env.getEnv("AWS_ENDPOINT"),
            };
            log.verbose("S3 credentials: loaded from environment variables (AWS_ACCESS_KEY_ID)");
        }

        if (s3Config == null) {
            log.verbose("S3 credentials: not configured (no vault entry, no env vars)");
        }
    }

    // --- Encryption key ---

    var encryptionKeyPems: []const IEncryptionKeyPem = &.{};

    const psiEncryptionKey = process_env.getEnv("PSI_ENCRYPTION_KEY");
    const entryEncryptionKey = if (entry) |dbEntry| dbEntry.encryptionKey else null;
    const hasAnyEncryptionSource = isTruthy(encryptionKey) or isTruthy(entryEncryptionKey) or isTruthy(psiEncryptionKey);

    if (hasAnyEncryptionSource) {
        if (isTruthy(encryptionKey)) {
            var pems: std.ArrayList(IEncryptionKeyPem) = .empty;
            var keyNames = std.mem.splitScalar(u8, encryptionKey.?, ',');
            while (keyNames.next()) |keyName| {
                const trimmedKeyName = std.mem.trim(u8, keyName, &std.ascii.whitespace);
                if (trimmedKeyName.len == 0) {
                    continue;
                }
                try pems.append(allocator, try resolveEncryptionKeyValue(allocator, io, vault, trimmedKeyName, "-k flag"));
            }
            encryptionKeyPems = pems.items;
        }
        else if (isTruthy(entryEncryptionKey)) {
            const secret = try vault.get(allocator, io, entryEncryptionKey.?) orelse {
                return errors.throwError("Encryption key \"{s}\" not found in vault", .{entryEncryptionKey.?});
            };
            const pems = try allocator.alloc(IEncryptionKeyPem, 1);
            pems[0] = try parseEncryptionKeyFromVaultValue(allocator, secret.value);
            encryptionKeyPems = pems;
            log.verbose(try std.fmt.allocPrint(allocator, "Encryption key: loaded from vault (key \"{s}\", via databases.json entry)", .{entryEncryptionKey.?}));
        }
        else if (isTruthy(psiEncryptionKey)) {
            const pem = try resolveEncryptionKeyValue(allocator, io, vault, psiEncryptionKey.?, "PSI_ENCRYPTION_KEY");
            const pems = try allocator.alloc(IEncryptionKeyPem, 1);
            pems[0] = pem;
            encryptionKeyPems = pems;
        }
    }
    else {
        log.verbose("Encryption key: not configured");
    }

    // --- Geocoding ---

    var googleApiKey: ?[]const u8 = null;

    const entryGeocodingKey = if (entry) |dbEntry| dbEntry.geocodingKey else null;
    const hasAnyGeocodingSource = isTruthy(entryGeocodingKey) or isTruthy(process_env.getEnv("GOOGLE_API_KEY"));

    if (hasAnyGeocodingSource) {
        if (isTruthy(entryGeocodingKey)) {
            const secret = try vault.get(allocator, io, entryGeocodingKey.?);
            if (secret) |geocodingSecret| {
                googleApiKey = geocodingSecret.value;
                log.verbose(try std.fmt.allocPrint(allocator, "Geocoding key: loaded from vault (key \"{s}\")", .{entryGeocodingKey.?}));
            }
            else {
                log.verbose(try std.fmt.allocPrint(allocator, "Geocoding key: vault key \"{s}\" not found", .{entryGeocodingKey.?}));
            }
        }

        if (!isTruthy(googleApiKey) and isTruthy(process_env.getEnv("GOOGLE_API_KEY"))) {
            googleApiKey = process_env.getEnv("GOOGLE_API_KEY");
            log.verbose("Geocoding key: loaded from environment variable (GOOGLE_API_KEY)");
        }
    }
    else {
        log.verbose("Geocoding key: not configured");
    }

    return .{ .s3Config = s3Config, .encryptionKeyPems = encryptionKeyPems, .googleApiKey = googleApiKey };
}

//
// Resolves an encryption key from a value that is either a filesystem path to a PEM file
// or a vault secret name. Throws if the value is neither.
//
pub fn resolveEncryptionKeyValue(
    allocator: std.mem.Allocator,
    io: std.Io,
    vault: IVault,
    value: []const u8,
    source: []const u8,
) !IEncryptionKeyPem {
    const isFile = node_utils.fs.pathExists(io, value);
    if (isFile) {
        const privateKeyPem = try std.Io.Dir.cwd().readFileAlloc(io, value, allocator, .unlimited);
        const privateKeyObj = try node_crypto.createPrivateKey(allocator, privateKeyPem);
        const publicKeyPem = try exportPublicKeyToPem(allocator, node_crypto.createPublicKeyFromPrivateKey(privateKeyObj));
        log.verbose(try std.fmt.allocPrint(allocator, "Encryption key: loaded from file \"{s}\" (via {s})", .{ value, source }));
        return .{ .privateKeyPem = privateKeyPem, .publicKeyPem = publicKeyPem };
    }

    const secret = try vault.get(allocator, io, value);
    if (secret) |keySecret| {
        const pem = try parseEncryptionKeyFromVaultValue(allocator, keySecret.value);
        log.verbose(try std.fmt.allocPrint(allocator, "Encryption key: loaded from vault (key \"{s}\", via {s})", .{ value, source }));
        return pem;
    }

    return errors.throwError("Encryption key \"{s}\" (via {s}) is neither a file path nor a vault secret name", .{ value, source });
}
