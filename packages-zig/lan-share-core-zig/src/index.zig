//
// Platform-agnostic LAN-share payload types and the shared secret-import loop. In TypeScript this zero-dependency
// package is shared by desktop (the Node `api` package, writing to the OS vault) and mobile.
//

const std = @import("std");

//
// Share payload for a single standalone secret.
//
pub const ISecretSharePayload = struct {
    // Discriminator for payload type ("secret").
    type: []const u8,

    // The name of the secret in the sender's vault.
    name: []const u8,

    // The category of the secret being shared ("s3-credentials", "encryption-key" or "api-key").
    secretType: []const u8,

    // JSON string containing the secret value, same format as the vault value field.
    value: []const u8,
};

//
// Resolved S3 credentials included in a share payload.
//
pub const IShareS3Credentials = struct {
    // The vault key name used by the sender.
    name: []const u8,

    // AWS region (e.g. "us-east-1").
    // (Zig: optional, because TypeScript sends whatever the stored credentials hold, and undefined when they
    // have no region; the same holds for the two keys.)
    region: ?[]const u8 = null,

    // Access key ID for authentication.
    accessKeyId: ?[]const u8 = null,

    // Secret access key for authentication.
    secretAccessKey: ?[]const u8 = null,

    // Optional custom endpoint URL (for non-AWS S3-compatible services).
    endpoint: ?[]const u8 = null,
};

//
// Resolved encryption key pair included in a share payload.
//
pub const IShareEncryptionKey = struct {
    // The vault key name used by the sender.
    name: []const u8,

    // PEM-encoded PKCS#8 private key.
    privateKeyPem: []const u8,

    // PEM-encoded SPKI public key. Optional -- receivers derive it from the private key when omitted.
    publicKeyPem: ?[]const u8 = null,
};

//
// Resolved geocoding API key included in a share payload.
//
pub const IShareGeocodingKey = struct {
    // The vault key name used by the sender.
    name: []const u8,

    // The API key value.
    apiKey: []const u8,
};

//
// Share payload for a full database configuration with all resolved secrets.
//
pub const IDatabaseSharePayload = struct {
    // Discriminator for payload type ("database").
    type: []const u8,

    // Human-readable name for the database.
    name: []const u8,

    // Description of the database.
    description: []const u8,

    // Filesystem or S3 path to the database.
    path: []const u8,

    // Optional origin string from the database config.
    origin: ?[]const u8 = null,

    // Resolved S3 credentials, if the database uses S3 storage.
    s3Credentials: ?IShareS3Credentials = null,

    // Resolved encryption key pair, if the database uses encryption.
    encryptionKey: ?IShareEncryptionKey = null,

    // Resolved geocoding API key, if configured.
    geocodingKey: ?IShareGeocodingKey = null,
};

//
// The action of a conflict resolution (the string union of IConflictResolution.action in TypeScript).
//
pub const ConflictAction = enum {
    // Overwrite the existing entry.
    replace,

    // Skip importing; keep the existing entry as-is.
    reuse,

    // Save the incoming secret under a different name.
    rename,
};

//
// Resolution chosen when an incoming secret name conflicts with an existing entry.
//
pub const IConflictResolution = struct {
    // 'replace': overwrite the existing entry.
    // 'reuse': skip importing; keep the existing entry as-is.
    // 'rename': save the incoming secret under a different name.
    action: ConflictAction,

    // Required when action is 'rename'; the new key name to use.
    newName: ?[]const u8 = null,
};

//
// Callback invoked when an incoming secret's name already exists. Returns how to resolve the
// conflict. An interactive caller (desktop) can prompt the user; a caller that already has
// the resolutions (mobile) simply returns them.
// (Zig: a context pointer and a function, called as `resolver.function(resolver.context, allocator, secretName,
// secretType)`.)
//
pub const ConflictResolver = struct {
    // The state the function works with.
    context: ?*anyopaque,

    // Returns the resolution for a secret whose name is taken.
    function: *const fn (context: ?*anyopaque, allocator: std.mem.Allocator, secretName: []const u8, secretType: []const u8) anyerror!IConflictResolution,
};

//
// The minimal storage a secret importer writes through, so this module never depends on a concrete
// vault or config store.
// (Zig: a context pointer and the two functions, each called with the context.)
//
pub const IShareSecretStore = struct {
    // The state the functions work with.
    context: ?*anyopaque,

    // Whether a secret with the given name already exists.
    has: *const fn (context: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!bool,

    // Creates or overwrites a secret with the given name, type and value.
    write: *const fn (context: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8, secretType: []const u8, value: []const u8) anyerror!void,
};

//
// The resolved secret key names for a received database, one per included secret (undefined when the
// database did not include that kind of secret). The caller uses these to build its database entry.
//
pub const IShareResolvedKeys = struct {
    // Final key name the S3 credentials were stored under.
    s3Key: ?[]const u8 = null,

    // Final key name the encryption key was stored under.
    encryptionKey: ?[]const u8 = null,

    // Final key name the geocoding API key was stored under.
    geocodingKey: ?[]const u8 = null,
};

//
// The final name a secret is stored under and whether its value should be written (false = the user
// chose to reuse the existing secret rather than overwrite it).
//
const IResolvedSecret = struct {
    // The name the secret is stored under (unchanged, or the rename target).
    finalName: []const u8,

    // Whether to write the value.
    shouldWrite: bool,
};

//
// Checks whether an incoming secret name already exists and, if so, applies the caller's conflict
// resolution. Returns the final name and whether the value should be written.
//
fn resolveConflict(allocator: std.mem.Allocator, store: IShareSecretStore, name: []const u8, secretType: []const u8, resolveConflictCallback: ConflictResolver) !IResolvedSecret {
    if (!(try store.has(store.context, allocator, name))) {
        return .{
            .finalName = name,
            .shouldWrite = true,
        };
    }

    const resolution = try resolveConflictCallback.function(resolveConflictCallback.context, allocator, name, secretType);

    if (resolution.action == .reuse) {
        return .{
            .finalName = name,
            .shouldWrite = false,
        };
    }

    if (resolution.action == .rename) {
        return .{
            .finalName = resolution.newName.?,
            .shouldWrite = true,
        };
    }

    return .{
        .finalName = name,
        .shouldWrite = true,
    };
}

//
// The value S3 credentials are stored with (the object literal JSON.stringify writes in importShareSecrets, keys in
// its order; an absent endpoint is left out).
//
const IStoredS3Credentials = struct {
    // AWS region (left out when undefined, like JSON.stringify leaves it out).
    region: ?[]const u8,

    // Access key ID (left out when undefined).
    accessKeyId: ?[]const u8,

    // Secret access key (left out when undefined).
    secretAccessKey: ?[]const u8,

    // Optional custom endpoint URL.
    endpoint: ?[]const u8,
};

//
// Writes each secret included in a received database payload (S3 credentials, encryption key,
// geocoding key), honouring per-secret conflict resolutions, and returns the final key names the
// caller's database entry should reference. This is the logic desktop and mobile previously
// duplicated: the only per-platform differences (which store, and how the resolved keys become a
// database entry) are supplied by the caller through `store` and the return value.
//
pub fn importShareSecrets(allocator: std.mem.Allocator, payload: IDatabaseSharePayload, store: IShareSecretStore, resolveConflictCallback: ConflictResolver) !IShareResolvedKeys {
    var resolvedKeys: IShareResolvedKeys = .{};

    if (payload.s3Credentials) |s3Credentials| {
        const resolved = try resolveConflict(allocator, store, s3Credentials.name, "s3-credentials", resolveConflictCallback);
        resolvedKeys.s3Key = resolved.finalName;
        if (resolved.shouldWrite) {
            const stored: IStoredS3Credentials = .{
                .region = s3Credentials.region,
                .accessKeyId = s3Credentials.accessKeyId,
                .secretAccessKey = s3Credentials.secretAccessKey,
                .endpoint = s3Credentials.endpoint,
            };
            const value = try std.json.Stringify.valueAlloc(allocator, stored, .{ .emit_null_optional_fields = false });
            try store.write(store.context, allocator, resolved.finalName, "s3-credentials", value);
        }
    }

    if (payload.encryptionKey) |encryptionKey| {
        const resolved = try resolveConflict(allocator, store, encryptionKey.name, "encryption-key", resolveConflictCallback);
        resolvedKeys.encryptionKey = resolved.finalName;
        if (resolved.shouldWrite) {
            try store.write(store.context, allocator, resolved.finalName, "encryption-key", encryptionKey.privateKeyPem);
        }
    }

    if (payload.geocodingKey) |geocodingKey| {
        const resolved = try resolveConflict(allocator, store, geocodingKey.name, "api-key", resolveConflictCallback);
        resolvedKeys.geocodingKey = resolved.finalName;
        if (resolved.shouldWrite) {
            try store.write(store.context, allocator, resolved.finalName, "api-key", geocodingKey.apiKey);
        }
    }

    return resolvedKeys;
}
