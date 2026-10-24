const std = @import("std");
const utils = @import("utils-zig");
const vault = @import("vault.zig");
const ISecret = vault.ISecret;
const IVault = vault.IVault;
const IPrereqCheckResult = vault.IPrereqCheckResult;
const INativeCaller = utils.native_caller.INativeCaller;
const errors = utils.errors;

//
// The device keychain key holding a secret's value, one item per secret. Followed by the secret's name.
//
pub const SECRET_VALUE_KEY_PREFIX = "photosphere.secret.";

//
// The device keychain key holding a secret's type, one item per secret, kept apart from the value so listing the secrets starts from
// the types alone. Followed by the secret's name.
//
pub const SECRET_TYPE_KEY_PREFIX = "photosphere.secret-type.";

//
// A vault that keeps its secrets in the phone's keychain, which only the phone's shell can reach. It asks the shell through the
// requester it was made with: secureStoreGet, secureStoreSet, secureStoreDelete and secureStoreKeys, each carrying and returning
// JSON text. Each secret is two keychain items, its value and its type.
//
pub const PhoneVault = struct {
    // Asks the phone's shell for the keychain.
    host: INativeCaller,

    //
    // Makes a vault that asks the given requester.
    //
    pub fn init(host: INativeCaller) PhoneVault {
        return .{
            .host = host,
        };
    }

    //
    // The IVault interface for this vault (the vault must not move while it is used).
    //
    pub fn vault(self: *PhoneVault) IVault {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // The IVault functions of this vault.
    //
    pub const vtable: IVault.VTable = .{
        .get = getErased,
        .set = setErased,
        .list = listErased,
        .delete = deleteErased,
        .checkPrereqs = checkPrereqsErased,
    };

    //
    // Reads one keychain item, or null when there is none.
    //
    fn readItem(self: *PhoneVault, allocator: std.mem.Allocator, io: std.Io, key: []const u8) !?[]const u8 {
        const request = try std.json.Stringify.valueAlloc(allocator, .{
            .key = key,
        }, .{});
        const answer = try self.host.call(io, allocator, "secureStoreGet", request);
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, answer, .{}) catch {
            return errors.throwError("The phone's answer to secureStoreGet could not be read.", .{});
        };
        const value = if (parsed == .object) parsed.object.get("value") else null;
        if (value == null) {
            return errors.throwError("The phone's answer to secureStoreGet has no value.", .{});
        }
        return switch (value.?) {
            .null => null,
            .string => |text| text,
            else => errors.throwError("The phone's answer to secureStoreGet has a value that is not text.", .{}),
        };
    }

    //
    // Writes one keychain item.
    //
    fn writeItem(self: *PhoneVault, allocator: std.mem.Allocator, io: std.Io, key: []const u8, value: []const u8) !void {
        const request = try std.json.Stringify.valueAlloc(allocator, .{
            .key = key,
            .value = value,
        }, .{});
        _ = try self.host.call(io, allocator, "secureStoreSet", request);
    }

    //
    // Deletes one keychain item. A missing item is not an error.
    //
    fn deleteItem(self: *PhoneVault, allocator: std.mem.Allocator, io: std.Io, key: []const u8) !void {
        const request = try std.json.Stringify.valueAlloc(allocator, .{
            .key = key,
        }, .{});
        _ = try self.host.call(io, allocator, "secureStoreDelete", request);
    }

    //
    // The name of every keychain item.
    //
    fn readKeys(self: *PhoneVault, allocator: std.mem.Allocator, io: std.Io) ![]const []const u8 {
        const answer = try self.host.call(io, allocator, "secureStoreKeys", "null");
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, answer, .{}) catch {
            return errors.throwError("The phone's answer to secureStoreKeys could not be read.", .{});
        };
        const keys = if (parsed == .object) parsed.object.get("keys") else null;
        if (keys == null or keys.? != .array) {
            return errors.throwError("The phone's answer to secureStoreKeys has no list of keys.", .{});
        }
        var names: std.ArrayList([]const u8) = .empty;
        for (keys.?.array.items) |item| {
            if (item != .string) {
                return errors.throwError("The phone's answer to secureStoreKeys has a key that is not text.", .{});
            }
            try names.append(allocator, item.string);
        }
        return names.items;
    }

    //
    // Retrieves a secret by name. Returns null if there is none of that name.
    // The worker's keychain vault reads the value alone, but IVault returns a whole secret, so the type is read too, and a value
    // with no type throws rather than return a secret with a made-up type.
    //
    pub fn get(self: *PhoneVault, allocator: std.mem.Allocator, io: std.Io, name: []const u8) !?ISecret {
        const value = try self.readItem(allocator, io, try std.mem.concat(allocator, u8, &.{ SECRET_VALUE_KEY_PREFIX, name })) orelse {
            return null;
        };
        const secret_type = try self.readItem(allocator, io, try std.mem.concat(allocator, u8, &.{ SECRET_TYPE_KEY_PREFIX, name })) orelse {
            return errors.throwError("The phone's keychain holds a value for the secret \"{s}\" but no type.", .{name});
        };
        return .{
            .name = name,
            .type = secret_type,
            .value = value,
        };
    }

    //
    // Creates or overwrites a secret. The value is written before the type, so an interrupted write leaves a value that is not listed
    // rather than a listed secret with no value.
    //
    pub fn set(self: *PhoneVault, allocator: std.mem.Allocator, io: std.Io, secret: ISecret) !void {
        try self.writeItem(allocator, io, try std.mem.concat(allocator, u8, &.{ SECRET_VALUE_KEY_PREFIX, secret.name }), secret.value);
        try self.writeItem(allocator, io, try std.mem.concat(allocator, u8, &.{ SECRET_TYPE_KEY_PREFIX, secret.name }), secret.type);
    }

    //
    // Returns every secret, starting from the type items. The type is read before the value, and a secret whose type or value is gone
    // since the keys were read (a delete running beside the list, which removes the type first) is skipped rather than reported.
    // Unlike listSecrets of the phone's secret store, which lists names and types only, each secret comes with its value, because
    // IVault.list returns whole secrets.
    //
    pub fn list(self: *PhoneVault, allocator: std.mem.Allocator, io: std.Io) ![]ISecret {
        var secrets: std.ArrayList(ISecret) = .empty;
        for (try self.readKeys(allocator, io)) |key| {
            if (!std.mem.startsWith(u8, key, SECRET_TYPE_KEY_PREFIX)) {
                continue;
            }
            const name = key[SECRET_TYPE_KEY_PREFIX.len..];
            const secret_type = try self.readItem(allocator, io, key) orelse {
                continue;
            };
            const value = try self.readItem(allocator, io, try std.mem.concat(allocator, u8, &.{ SECRET_VALUE_KEY_PREFIX, name })) orelse {
                continue;
            };
            try secrets.append(allocator, .{
                .name = name,
                .type = secret_type,
                .value = value,
            });
        }
        return secrets.items;
    }

    //
    // Deletes a secret by name. The type goes first, so the secret leaves the list before its value goes.
    //
    pub fn delete(self: *PhoneVault, allocator: std.mem.Allocator, io: std.Io, name: []const u8) !void {
        try self.deleteItem(allocator, io, try std.mem.concat(allocator, u8, &.{ SECRET_TYPE_KEY_PREFIX, name }));
        try self.deleteItem(allocator, io, try std.mem.concat(allocator, u8, &.{ SECRET_VALUE_KEY_PREFIX, name }));
    }

    //
    // The phone's keychain needs no tools installed.
    //
    pub fn checkPrereqs(self: *PhoneVault) IPrereqCheckResult {
        _ = self;
        return .{
            .ok = true,
            .message = null,
        };
    }

    fn getErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, name: []const u8) anyerror!?ISecret {
        const self: *PhoneVault = @ptrCast(@alignCast(ptr));
        return self.get(allocator, io, name);
    }

    fn setErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, secret: ISecret) anyerror!void {
        const self: *PhoneVault = @ptrCast(@alignCast(ptr));
        return self.set(allocator, io, secret);
    }

    fn listErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror![]ISecret {
        const self: *PhoneVault = @ptrCast(@alignCast(ptr));
        return self.list(allocator, io);
    }

    fn deleteErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, name: []const u8) anyerror!void {
        const self: *PhoneVault = @ptrCast(@alignCast(ptr));
        return self.delete(allocator, io, name);
    }

    fn checkPrereqsErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!IPrereqCheckResult {
        _ = allocator;
        _ = io;
        const self: *PhoneVault = @ptrCast(@alignCast(ptr));
        return self.checkPrereqs();
    }
};
