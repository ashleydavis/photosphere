const std = @import("std");
const vault_zig = @import("vault-zig");
const utils = @import("utils-zig");
const PhoneVault = vault_zig.phone_vault.PhoneVault;
const ISecret = vault_zig.vault.ISecret;
const IHostRequester = utils.host_requester.IHostRequester;
const errors = utils.errors;
const node_utils = @import("node-utils-zig");
const isolated_vault = @import("isolated-vault.zig");

//
// A host that keeps keychain items in memory and answers the secureStore requests the way the phone's shell does. It records the
// methods it was asked for.
//
const MemoryHost = struct {
    // The items by key.
    items: std.StringHashMapUnmanaged([]const u8),

    // Where the items are kept.
    allocator: std.mem.Allocator,

    // The methods asked for, in order.
    methods: std.ArrayList([]const u8),

    // Set to make every request fail with this reason.
    failure: ?[]const u8,

    // Set to make a secureStoreSet of this key fail.
    failing_set_key: ?[]const u8,

    fn init(allocator: std.mem.Allocator) MemoryHost {
        return .{
            .items = .empty,
            .allocator = allocator,
            .methods = .empty,
            .failure = null,
            .failing_set_key = null,
        };
    }

    fn requester(self: *MemoryHost) IHostRequester {
        return .{
            .ptr = self,
            .request = request,
        };
    }

    fn request(ptr: *anyopaque, allocator: std.mem.Allocator, method: []const u8, request_json: []const u8) anyerror![]const u8 {
        const self: *MemoryHost = @ptrCast(@alignCast(ptr));
        try self.methods.append(self.allocator, try self.allocator.dupe(u8, method));
        if (self.failure) |reason| {
            return errors.throwError("{s}", .{reason});
        }
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, request_json, .{});
        if (std.mem.eql(u8, method, "secureStoreGet")) {
            const value = self.items.get(parsed.object.get("key").?.string);
            return try std.json.Stringify.valueAlloc(allocator, .{
                .value = value,
            }, .{});
        }
        if (std.mem.eql(u8, method, "secureStoreSet")) {
            if (self.failing_set_key) |failing_key| {
                if (std.mem.eql(u8, failing_key, parsed.object.get("key").?.string)) {
                    return errors.throwError("The write of {s} failed", .{failing_key});
                }
            }
            try self.items.put(self.allocator, try self.allocator.dupe(u8, parsed.object.get("key").?.string), try self.allocator.dupe(u8, parsed.object.get("value").?.string));
            return try allocator.dupe(u8, "null");
        }
        if (std.mem.eql(u8, method, "secureStoreDelete")) {
            _ = self.items.remove(parsed.object.get("key").?.string);
            return try allocator.dupe(u8, "null");
        }
        if (std.mem.eql(u8, method, "secureStoreKeys")) {
            var keys: std.ArrayList([]const u8) = .empty;
            var iterator = self.items.keyIterator();
            while (iterator.next()) |key| {
                try keys.append(allocator, key.*);
            }
            return try std.json.Stringify.valueAlloc(allocator, .{
                .keys = keys.items,
            }, .{});
        }
        return errors.throwError("unexpected method {s}", .{method});
    }
};

test "PhoneVault: get returns null for a secret that is not there" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = MemoryHost.init(arena.allocator());
    var phone = PhoneVault.init(host.requester());
    const vault = phone.vault();
    try std.testing.expect(try vault.get(arena.allocator(), std.testing.io, "missing") == null);
}

test "PhoneVault: set then get returns the name, type and value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = MemoryHost.init(arena.allocator());
    var phone = PhoneVault.init(host.requester());
    const vault = phone.vault();
    try vault.set(arena.allocator(), std.testing.io, .{
        .name = "my-s3",
        .type = "s3-credentials",
        .value = "{\"accessKeyId\":\"a\"}",
    });
    const secret = (try vault.get(arena.allocator(), std.testing.io, "my-s3")).?;
    try std.testing.expectEqualStrings("my-s3", secret.name);
    try std.testing.expectEqualStrings("s3-credentials", secret.type);
    try std.testing.expectEqualStrings("{\"accessKeyId\":\"a\"}", secret.value);
}

test "PhoneVault: set stores the value under the value key and the type under the type key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = MemoryHost.init(arena.allocator());
    var phone = PhoneVault.init(host.requester());
    try phone.vault().set(arena.allocator(), std.testing.io, .{
        .name = "key1",
        .type = "plain",
        .value = "secret-value",
    });
    try std.testing.expectEqualStrings("secret-value", host.items.get("photosphere.secret.key1").?);
    try std.testing.expectEqualStrings("plain", host.items.get("photosphere.secret-type.key1").?);
    try std.testing.expectEqual(@as(u32, 2), host.items.count());
}

test "PhoneVault: set overwrites a secret of the same name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = MemoryHost.init(arena.allocator());
    var phone = PhoneVault.init(host.requester());
    const vault = phone.vault();
    try vault.set(arena.allocator(), std.testing.io, .{
        .name = "a",
        .type = "plain",
        .value = "one",
    });
    try vault.set(arena.allocator(), std.testing.io, .{
        .name = "a",
        .type = "api-key",
        .value = "two",
    });
    const secret = (try vault.get(arena.allocator(), std.testing.io, "a")).?;
    try std.testing.expectEqualStrings("api-key", secret.type);
    try std.testing.expectEqualStrings("two", secret.value);
}

test "PhoneVault: delete removes both items and does nothing for a missing secret" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = MemoryHost.init(arena.allocator());
    var phone = PhoneVault.init(host.requester());
    const vault = phone.vault();
    try vault.set(arena.allocator(), std.testing.io, .{
        .name = "a",
        .type = "plain",
        .value = "one",
    });
    try vault.delete(arena.allocator(), std.testing.io, "a");
    try std.testing.expectEqual(@as(u32, 0), host.items.count());
    try vault.delete(arena.allocator(), std.testing.io, "never-there");
}

test "PhoneVault: list returns every secret and ignores other keychain items" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = MemoryHost.init(arena.allocator());
    var phone = PhoneVault.init(host.requester());
    const vault = phone.vault();
    try vault.set(arena.allocator(), std.testing.io, .{
        .name = "a",
        .type = "plain",
        .value = "one",
    });
    try vault.set(arena.allocator(), std.testing.io, .{
        .name = "b",
        .type = "api-key",
        .value = "two",
    });
    try host.items.put(arena.allocator(), "something.else", "x");
    const secrets = try vault.list(arena.allocator(), std.testing.io);
    try std.testing.expectEqual(@as(usize, 2), secrets.len);
    var found_a = false;
    var found_b = false;
    for (secrets) |secret| {
        if (std.mem.eql(u8, secret.name, "a")) {
            found_a = true;
            try std.testing.expectEqualStrings("one", secret.value);
        }
        if (std.mem.eql(u8, secret.name, "b")) {
            found_b = true;
            try std.testing.expectEqualStrings("api-key", secret.type);
        }
    }
    try std.testing.expect(found_a and found_b);
}

test "PhoneVault: a value with no type is an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = MemoryHost.init(arena.allocator());
    try host.items.put(arena.allocator(), "photosphere.secret.orphan", "v");
    var phone = PhoneVault.init(host.requester());
    try std.testing.expectError(error.Thrown, phone.vault().get(arena.allocator(), std.testing.io, "orphan"));
    try std.testing.expect(std.mem.indexOf(u8, errors.lastErrorMessage(), "no type") != null);
}

test "PhoneVault: a failing host fails the call with its reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = MemoryHost.init(arena.allocator());
    host.failure = "The device keychain could not be opened";
    var phone = PhoneVault.init(host.requester());
    try std.testing.expectError(error.Thrown, phone.vault().get(arena.allocator(), std.testing.io, "a"));
    try std.testing.expectEqualStrings("The device keychain could not be opened", errors.lastErrorMessage());
}

test "PhoneVault: checkPrereqs is ok" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = MemoryHost.init(arena.allocator());
    var phone = PhoneVault.init(host.requester());
    const result = try phone.vault().checkPrereqs(arena.allocator(), std.testing.io);
    try std.testing.expect(result.ok);
}

test "getVaultWithHost: the phone type returns a PhoneVault that asks the given host" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = MemoryHost.init(arena.allocator());
    const vault = try vault_zig.get_vault.getVaultWithHost(arena.allocator(), "phone", host.requester());
    try std.testing.expect(vault.vtable == &PhoneVault.vtable);
    _ = try vault.get(arena.allocator(), std.testing.io, "x");
    try std.testing.expectEqual(@as(usize, 1), host.methods.items.len);
    try std.testing.expectEqualStrings("secureStoreGet", host.methods.items[0]);
}

test "getVaultWithHost: the phone type without a host is an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Thrown, vault_zig.get_vault.getVaultWithHost(arena.allocator(), "phone", null));
    try std.testing.expect(std.mem.indexOf(u8, errors.lastErrorMessage(), "phone vault needs") != null);
}

test "getVaultWithHost: another type is the vault getVault returns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const previous = node_utils.process_env.getEnvironMap();
    node_utils.process_env.setEnvironMap(try isolated_vault.environmentWithIsolatedVault(arena.allocator(), std.testing.io));
    defer node_utils.process_env.setEnvironMap(previous);
    const vault = try vault_zig.get_vault.getVaultWithHost(arena.allocator(), "plaintext", null);
    try std.testing.expect(vault.vtable == &vault_zig.plaintext_vault.PlaintextVault.vtable);
}

test "PhoneVault: a failed value write leaves the secret unlisted rather than listed with no value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = MemoryHost.init(arena.allocator());
    host.failing_set_key = "photosphere.secret.api";
    var phone = PhoneVault.init(host.requester());
    const vault = phone.vault();

    try std.testing.expectError(error.Thrown, vault.set(arena.allocator(), std.testing.io, .{
        .name = "api",
        .type = "api-key",
        .value = "v1",
    }));

    const secrets = try vault.list(arena.allocator(), std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), secrets.len);
}

test "PhoneVault: a secret name containing the type prefix does not confuse the enumeration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var host = MemoryHost.init(arena.allocator());
    var phone = PhoneVault.init(host.requester());
    const vault = phone.vault();

    // A name that embeds the other prefix would break any scheme that split keys on a separator.
    try vault.set(arena.allocator(), std.testing.io, .{
        .name = "photosphere.secret-type.tricky",
        .type = "api-key",
        .value = "v1",
    });

    const secrets = try vault.list(arena.allocator(), std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), secrets.len);
    try std.testing.expectEqualStrings("photosphere.secret-type.tricky", secrets[0].name);
    try std.testing.expectEqualStrings("api-key", secrets[0].type);
    const secret = (try vault.get(arena.allocator(), std.testing.io, "photosphere.secret-type.tricky")).?;
    try std.testing.expectEqualStrings("v1", secret.value);
}
