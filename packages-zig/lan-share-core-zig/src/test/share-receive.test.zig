const std = @import("std");
const lan_share_core = @import("lan-share-core-zig");

const importShareSecrets = lan_share_core.importShareSecrets;
const IDatabaseSharePayload = lan_share_core.IDatabaseSharePayload;
const IShareSecretStore = lan_share_core.IShareSecretStore;
const IConflictResolution = lan_share_core.IConflictResolution;
const ConflictResolver = lan_share_core.ConflictResolver;

//
// A secret persisted by the fake store: its type and value.
//
const IStoredSecret = struct {
    // The type the secret was written with.
    secretType: []const u8,

    // The value the secret was written with.
    value: []const u8,
};

//
// A fake secret store backed by a plain map, recording writes so tests can assert what was persisted.
//
const FakeSecretStore = struct {
    // The persisted secrets, keyed by name.
    secrets: std.StringArrayHashMapUnmanaged(IStoredSecret) = .empty,

    //
    // Creates a store in which the given names already exist (to force a conflict).
    //
    fn init(allocator: std.mem.Allocator, existing: []const []const u8) !FakeSecretStore {
        var fakeStore: FakeSecretStore = .{};
        for (existing) |name| {
            try fakeStore.secrets.put(allocator, name, .{
                .secretType = "pre-existing",
                .value = "pre-existing",
            });
        }
        return fakeStore;
    }

    //
    // Whether a secret with the given name exists.
    //
    fn has(context: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!bool {
        _ = allocator;
        const self: *FakeSecretStore = @ptrCast(@alignCast(context.?));
        return self.secrets.contains(name);
    }

    //
    // Creates or overwrites a secret.
    //
    fn write(context: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8, secretType: []const u8, value: []const u8) anyerror!void {
        const self: *FakeSecretStore = @ptrCast(@alignCast(context.?));
        try self.secrets.put(allocator, name, .{
            .secretType = secretType,
            .value = value,
        });
    }

    //
    // The IShareSecretStore the importer writes through.
    //
    fn secretStore(self: *FakeSecretStore) IShareSecretStore {
        return .{
            .context = self,
            .has = has,
            .write = write,
        };
    }
};

//
// A conflict resolver that always returns the given resolution and records the names it was asked about.
//
const FixedResolver = struct {
    // The resolution returned for every conflict.
    resolution: IConflictResolution,

    // The names the resolver was asked about.
    asked: std.ArrayList([]const u8) = .empty,

    //
    // Records the name and returns the resolution.
    //
    fn resolve(context: ?*anyopaque, allocator: std.mem.Allocator, secretName: []const u8, secretType: []const u8) anyerror!IConflictResolution {
        _ = secretType;
        const self: *FixedResolver = @ptrCast(@alignCast(context.?));
        try self.asked.append(allocator, secretName);
        return self.resolution;
    }

    //
    // The ConflictResolver handed to the importer.
    //
    fn resolver(self: *FixedResolver) ConflictResolver {
        return .{
            .context = self,
            .function = resolve,
        };
    }
};

//
// A database payload carrying all three kinds of secret.
//
fn fullPayload() IDatabaseSharePayload {
    return .{
        .type = "database",
        .name = "db",
        .description = "",
        .path = "/data/db",
        .s3Credentials = .{
            .name = "s3-secret",
            .region = "us-east-1",
            .accessKeyId = "AK",
            .secretAccessKey = "SK",
            .endpoint = "https://example.com",
        },
        .encryptionKey = .{
            .name = "enc-secret",
            .privateKeyPem = "-----PEM-----",
        },
        .geocodingKey = .{
            .name = "geo-secret",
            .apiKey = "geo-value",
        },
    };
}

//
// Checks a secret in the fake store has this type and value.
//
fn expectStored(store: *FakeSecretStore, name: []const u8, secretType: []const u8, value: []const u8) !void {
    const stored = store.secrets.get(name) orelse {
        std.debug.print("No secret named {s} was stored\n", .{name});
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqualStrings(secretType, stored.secretType);
    try std.testing.expectEqualStrings(value, stored.value);
}

test "writes each included secret and returns the resolved key names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = try FakeSecretStore.init(allocator, &.{});
    var resolver: FixedResolver = .{
        .resolution = .{
            .action = .replace,
        },
    };

    const resolvedKeys = try importShareSecrets(allocator, fullPayload(), store.secretStore(), resolver.resolver());

    try std.testing.expectEqualStrings("s3-secret", resolvedKeys.s3Key.?);
    try std.testing.expectEqualStrings("enc-secret", resolvedKeys.encryptionKey.?);
    try std.testing.expectEqualStrings("geo-secret", resolvedKeys.geocodingKey.?);
    try std.testing.expectEqual(@as(usize, 0), resolver.asked.items.len);
    try expectStored(&store, "s3-secret", "s3-credentials", "{\"region\":\"us-east-1\",\"accessKeyId\":\"AK\",\"secretAccessKey\":\"SK\",\"endpoint\":\"https://example.com\"}");
    try expectStored(&store, "enc-secret", "encryption-key", "-----PEM-----");
    try expectStored(&store, "geo-secret", "api-key", "geo-value");
}

test "reuse keeps the existing secret and does not overwrite it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = try FakeSecretStore.init(allocator, &.{"geo-secret"});
    var resolver: FixedResolver = .{
        .resolution = .{
            .action = .reuse,
        },
    };

    const resolvedKeys = try importShareSecrets(allocator, fullPayload(), store.secretStore(), resolver.resolver());

    try std.testing.expectEqual(@as(usize, 1), resolver.asked.items.len);
    try std.testing.expectEqualStrings("geo-secret", resolver.asked.items[0]);
    try std.testing.expectEqualStrings("geo-secret", resolvedKeys.geocodingKey.?);
    // The pre-existing value is retained, not overwritten with the incoming one.
    try expectStored(&store, "geo-secret", "pre-existing", "pre-existing");
}

test "rename stores the incoming secret under the new name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = try FakeSecretStore.init(allocator, &.{"geo-secret"});
    var resolver: FixedResolver = .{
        .resolution = .{
            .action = .rename,
            .newName = "geo-secret-2",
        },
    };

    const resolvedKeys = try importShareSecrets(allocator, fullPayload(), store.secretStore(), resolver.resolver());

    try std.testing.expectEqualStrings("geo-secret-2", resolvedKeys.geocodingKey.?);
    try expectStored(&store, "geo-secret-2", "api-key", "geo-value");
    try expectStored(&store, "geo-secret", "pre-existing", "pre-existing");
}

test "replace overwrites an existing secret" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = try FakeSecretStore.init(allocator, &.{"geo-secret"});
    var resolver: FixedResolver = .{
        .resolution = .{
            .action = .replace,
        },
    };

    _ = try importShareSecrets(allocator, fullPayload(), store.secretStore(), resolver.resolver());

    try std.testing.expectEqual(@as(usize, 1), resolver.asked.items.len);
    try std.testing.expectEqualStrings("geo-secret", resolver.asked.items[0]);
    try expectStored(&store, "geo-secret", "api-key", "geo-value");
}

test "omitted secrets leave their resolved key undefined" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = try FakeSecretStore.init(allocator, &.{});
    var resolver: FixedResolver = .{
        .resolution = .{
            .action = .replace,
        },
    };
    const payload: IDatabaseSharePayload = .{
        .type = "database",
        .name = "db",
        .description = "",
        .path = "/data/db",
        .geocodingKey = .{
            .name = "geo-secret",
            .apiKey = "geo-value",
        },
    };

    const resolvedKeys = try importShareSecrets(allocator, payload, store.secretStore(), resolver.resolver());

    try std.testing.expect(resolvedKeys.s3Key == null);
    try std.testing.expect(resolvedKeys.encryptionKey == null);
    try std.testing.expectEqualStrings("geo-secret", resolvedKeys.geocodingKey.?);
    try std.testing.expect(!store.secrets.contains("s3-secret"));
}

test "an S3 endpoint that is absent is left out of the stored value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = try FakeSecretStore.init(allocator, &.{});
    var resolver: FixedResolver = .{
        .resolution = .{
            .action = .replace,
        },
    };
    const payload: IDatabaseSharePayload = .{
        .type = "database",
        .name = "db",
        .description = "",
        .path = "/data/db",
        .s3Credentials = .{
            .name = "s3-secret",
            .region = "r",
            .accessKeyId = "AK",
            .secretAccessKey = "SK",
        },
    };

    _ = try importShareSecrets(allocator, payload, store.secretStore(), resolver.resolver());

    // JSON.stringify leaves out a property whose value is undefined.
    try expectStored(&store, "s3-secret", "s3-credentials", "{\"region\":\"r\",\"accessKeyId\":\"AK\",\"secretAccessKey\":\"SK\"}");
}
