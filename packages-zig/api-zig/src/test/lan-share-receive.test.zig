const std = @import("std");
const api = @import("api-zig");
const vault_zig = @import("vault-zig");
const test_vault = @import("lan-share-test-vault.zig");

const importSecretPayload = api.lan_share_receive.importSecretPayload;
const importDatabasePayload = api.lan_share_receive.importDatabasePayload;
const ISecretSharePayload = api.lan_share.ISecretSharePayload;
const IDatabaseSharePayload = api.lan_share.IDatabaseSharePayload;
const IConflictResolution = api.lan_share.IConflictResolution;
const ConflictResolver = api.lan_share.ConflictResolver;
const getVault = vault_zig.get_vault.getVault;

//
// A conflict resolver that returns a fixed resolution and records the calls it gets (the `jest.fn()` resolvers of
// the TypeScript tests).
//
const RecordingResolver = struct {
    // The resolution returned for every conflict.
    resolution: IConflictResolution,

    // The secret names the resolver was called with.
    names: std.ArrayList([]const u8) = .empty,

    // The secret types the resolver was called with.
    types: std.ArrayList([]const u8) = .empty,

    //
    // Records the call and returns the resolution.
    //
    fn resolve(context: ?*anyopaque, allocator: std.mem.Allocator, secretName: []const u8, secretType: []const u8) anyerror!IConflictResolution {
        const self: *RecordingResolver = @ptrCast(@alignCast(context.?));
        try self.names.append(allocator, secretName);
        try self.types.append(allocator, secretType);
        return self.resolution;
    }

    //
    // The ConflictResolver handed to importDatabasePayload.
    //
    fn resolver(self: *RecordingResolver) ConflictResolver {
        return .{
            .context = self,
            .function = resolve,
        };
    }
};

//
// Sets up a test: the test vault, emptied (the TypeScript tests reset their vault mocks before each test).
//
fn useEmptyVault(allocator: std.mem.Allocator, io: std.Io) !vault_zig.vault.IVault {
    try test_vault.useTestVault();
    try test_vault.clearTestVault(allocator, io);
    return getVault("plaintext");
}

//
// Finds the one secret of a type in a list of secrets (the `mockVaultSet.mock.calls.find` of the TypeScript tests).
//
fn secretOfType(secrets: []const vault_zig.vault.ISecret, secretType: []const u8) ?vault_zig.vault.ISecret {
    for (secrets) |secret| {
        if (std.mem.eql(u8, secret.type, secretType)) {
            return secret;
        }
    }
    return null;
}

//
// A payload with only S3 credentials named "default:s3" (the payload of the conflict resolver tests).
//
fn s3OnlyPayload() IDatabaseSharePayload {
    return .{
        .type = "database",
        .name = "test-db",
        .description = "",
        .path = "/data/test",
        .s3Credentials = .{
            .name = "default:s3",
            .region = "us-east-1",
            .accessKeyId = "AK",
            .secretAccessKey = "SK",
        },
    };
}

test "imports database payload with all secrets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const vault = try useEmptyVault(allocator, io);
    defer test_vault.useRealEnvironment();
    var resolver: RecordingResolver = .{
        .resolution = .{
            .action = .replace,
        },
    };
    const payload: IDatabaseSharePayload = .{
        .type = "database",
        .name = "shared-photos",
        .description = "Photos from another device",
        .path = "/data/shared-photos",
        .origin = "https://example.com",
        .s3Credentials = .{
            .name = "default:s3",
            .region = "us-east-1",
            .accessKeyId = "AKID",
            .secretAccessKey = "SECRET",
            .endpoint = "https://s3.example.com",
        },
        .encryptionKey = .{
            .name = "digital-ocean",
            .privateKeyPem = "-----PRIVATE-----",
            .publicKeyPem = "-----PUBLIC-----",
        },
        .geocodingKey = .{
            .name = "geocoding-key",
            .apiKey = "geo-key-123",
        },
    };

    const entry = try importDatabasePayload(allocator, io, payload, resolver.resolver());

    try std.testing.expectEqualStrings("shared-photos", entry.name);
    try std.testing.expectEqualStrings("Photos from another device", entry.description);
    try std.testing.expectEqualStrings("/data/shared-photos", entry.path);
    try std.testing.expectEqualStrings("https://example.com", entry.origin.?);
    try std.testing.expect(entry.s3Key != null);
    try std.testing.expect(entry.encryptionKey != null);
    try std.testing.expect(entry.geocodingKey != null);

    // One secret stored for each included secret.
    const secrets = try vault.list(allocator, io);
    try std.testing.expectEqual(@as(usize, 3), secrets.len);

    // Verify S3 credential was stored
    const s3Secret = secretOfType(secrets, "s3-credentials").?;
    const s3Value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, s3Secret.value, .{});
    try std.testing.expect(s3Value.object.get("label") == null);
    try std.testing.expectEqualStrings("us-east-1", s3Value.object.get("region").?.string);

    // Verify encryption key was stored as raw PEM
    try std.testing.expectEqualStrings("-----PRIVATE-----", secretOfType(secrets, "encryption-key").?.value);

    // Verify geocoding key was stored as raw string
    try std.testing.expectEqualStrings("geo-key-123", secretOfType(secrets, "api-key").?.value);
}

test "imports database payload with no secrets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const vault = try useEmptyVault(allocator, io);
    defer test_vault.useRealEnvironment();
    var resolver: RecordingResolver = .{
        .resolution = .{
            .action = .replace,
        },
    };
    const payload: IDatabaseSharePayload = .{
        .type = "database",
        .name = "simple-db",
        .description = "",
        .path = "/data/simple",
    };

    const entry = try importDatabasePayload(allocator, io, payload, resolver.resolver());

    try std.testing.expectEqualStrings("simple-db", entry.name);
    try std.testing.expect(entry.s3Key == null);
    try std.testing.expect(entry.encryptionKey == null);
    try std.testing.expect(entry.geocodingKey == null);
    try std.testing.expectEqual(@as(usize, 0), (try vault.list(allocator, io)).len);
}

test "imports secret payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    try test_vault.useTestVault();
    defer test_vault.useRealEnvironment();
    const payload: ISecretSharePayload = .{
        .type = "secret",
        .name = "s3:my-s3",
        .secretType = "s3-credentials",
        .value = "{\"region\":\"us-east-1\",\"accessKeyId\":\"AKID\",\"secretAccessKey\":\"SECRET\"}",
    };

    try importSecretPayload(allocator, io, payload, "imported1");

    const vault = try getVault("plaintext");
    const secret = (try vault.get(allocator, io, "imported1")).?;
    try std.testing.expectEqualStrings("imported1", secret.name);
    try std.testing.expectEqualStrings("s3-credentials", secret.type);
    try std.testing.expectEqualStrings(payload.value, secret.value);
    try std.testing.expect((try vault.get(allocator, io, "s3:my-s3")) == null);
}

test "imported database entry uses secret names from payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try useEmptyVault(allocator, io);
    defer test_vault.useRealEnvironment();
    var resolver: RecordingResolver = .{
        .resolution = .{
            .action = .replace,
        },
    };
    const payload: IDatabaseSharePayload = .{
        .type = "database",
        .name = "test-db",
        .description = "",
        .path = "/data/test",
        .s3Credentials = .{
            .name = "default:s3",
            .region = "us-east-1",
            .accessKeyId = "AK",
            .secretAccessKey = "SK",
        },
        .encryptionKey = .{
            .name = "digital-ocean",
            .privateKeyPem = "priv",
            .publicKeyPem = "pub",
        },
    };

    const entry = try importDatabasePayload(allocator, io, payload, resolver.resolver());

    // Secret names should match those in the payload, not random IDs.
    try std.testing.expectEqualStrings("default:s3", entry.s3Key.?);
    try std.testing.expectEqualStrings("digital-ocean", entry.encryptionKey.?);
}

test "conflict resolver reuse: skips vault.set and keeps original name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const vault = try useEmptyVault(allocator, io);
    defer test_vault.useRealEnvironment();
    try vault.set(allocator, io, .{
        .name = "default:s3",
        .type = "s3-credentials",
        .value = "{}",
    });
    var resolver: RecordingResolver = .{
        .resolution = .{
            .action = .reuse,
        },
    };

    const entry = try importDatabasePayload(allocator, io, s3OnlyPayload(), resolver.resolver());

    try std.testing.expectEqual(@as(usize, 1), resolver.names.items.len);
    try std.testing.expectEqualStrings("default:s3", resolver.names.items[0]);
    try std.testing.expectEqualStrings("s3-credentials", resolver.types.items[0]);
    // The existing secret is kept as it was.
    try std.testing.expectEqualStrings("{}", (try vault.get(allocator, io, "default:s3")).?.value);
    try std.testing.expectEqual(@as(usize, 1), (try vault.list(allocator, io)).len);
    try std.testing.expectEqualStrings("default:s3", entry.s3Key.?);
}

test "conflict resolver replace: calls vault.set with original name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const vault = try useEmptyVault(allocator, io);
    defer test_vault.useRealEnvironment();
    try vault.set(allocator, io, .{
        .name = "default:s3",
        .type = "s3-credentials",
        .value = "{}",
    });
    var resolver: RecordingResolver = .{
        .resolution = .{
            .action = .replace,
        },
    };

    const entry = try importDatabasePayload(allocator, io, s3OnlyPayload(), resolver.resolver());

    try std.testing.expectEqual(@as(usize, 1), resolver.names.items.len);
    try std.testing.expectEqualStrings("default:s3", resolver.names.items[0]);
    try std.testing.expectEqualStrings("s3-credentials", resolver.types.items[0]);
    try std.testing.expectEqualStrings("{\"region\":\"us-east-1\",\"accessKeyId\":\"AK\",\"secretAccessKey\":\"SK\"}", (try vault.get(allocator, io, "default:s3")).?.value);
    try std.testing.expectEqual(@as(usize, 1), (try vault.list(allocator, io)).len);
    try std.testing.expectEqualStrings("default:s3", entry.s3Key.?);
}

test "conflict resolver rename: calls vault.set with new name and updates entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const vault = try useEmptyVault(allocator, io);
    defer test_vault.useRealEnvironment();
    try vault.set(allocator, io, .{
        .name = "default:s3",
        .type = "s3-credentials",
        .value = "{}",
    });
    var resolver: RecordingResolver = .{
        .resolution = .{
            .action = .rename,
            .newName = "default:s3-imported",
        },
    };

    const entry = try importDatabasePayload(allocator, io, s3OnlyPayload(), resolver.resolver());

    try std.testing.expectEqual(@as(usize, 1), resolver.names.items.len);
    try std.testing.expectEqualStrings("default:s3", resolver.names.items[0]);
    try std.testing.expectEqualStrings("s3-credentials", resolver.types.items[0]);
    try std.testing.expectEqualStrings("{\"region\":\"us-east-1\",\"accessKeyId\":\"AK\",\"secretAccessKey\":\"SK\"}", (try vault.get(allocator, io, "default:s3-imported")).?.value);
    try std.testing.expectEqualStrings("{}", (try vault.get(allocator, io, "default:s3")).?.value);
    try std.testing.expectEqualStrings("default:s3-imported", entry.s3Key.?);
}

test "conflict resolver not called when no existing secret" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const vault = try useEmptyVault(allocator, io);
    defer test_vault.useRealEnvironment();
    var resolver: RecordingResolver = .{
        .resolution = .{
            .action = .reuse,
        },
    };

    _ = try importDatabasePayload(allocator, io, s3OnlyPayload(), resolver.resolver());

    try std.testing.expectEqual(@as(usize, 0), resolver.names.items.len);
    try std.testing.expectEqual(@as(usize, 1), (try vault.list(allocator, io)).len);
}

test "stores encryption-key as raw PEM, not JSON-wrapped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const vault = try useEmptyVault(allocator, io);
    defer test_vault.useRealEnvironment();
    var resolver: RecordingResolver = .{
        .resolution = .{
            .action = .replace,
        },
    };
    const payload: IDatabaseSharePayload = .{
        .type = "database",
        .name = "test-db",
        .description = "",
        .path = "/data/test",
        .encryptionKey = .{
            .name = "enc-secret",
            .privateKeyPem = "-----RAW PRIVATE-----",
            .publicKeyPem = "-----RAW PUBLIC-----",
        },
    };

    _ = try importDatabasePayload(allocator, io, payload, resolver.resolver());

    try std.testing.expectEqual(@as(usize, 1), (try vault.list(allocator, io)).len);
    try std.testing.expectEqualStrings("-----RAW PRIVATE-----", (try vault.get(allocator, io, "enc-secret")).?.value);
}

test "stores api-key as raw string, not JSON-wrapped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const vault = try useEmptyVault(allocator, io);
    defer test_vault.useRealEnvironment();
    var resolver: RecordingResolver = .{
        .resolution = .{
            .action = .replace,
        },
    };
    const payload: IDatabaseSharePayload = .{
        .type = "database",
        .name = "test-db",
        .description = "",
        .path = "/data/test",
        .geocodingKey = .{
            .name = "geo-secret",
            .apiKey = "raw-api-key-value",
        },
    };

    _ = try importDatabasePayload(allocator, io, payload, resolver.resolver());

    try std.testing.expectEqual(@as(usize, 1), (try vault.list(allocator, io)).len);
    try std.testing.expectEqualStrings("raw-api-key-value", (try vault.get(allocator, io, "geo-secret")).?.value);
}
