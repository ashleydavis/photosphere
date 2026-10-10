const std = @import("std");
const utils = @import("utils-zig");
const vault_module = @import("vault.zig");
const ISecret = vault_module.ISecret;
const IVault = vault_module.IVault;
const IPrereqCheckResult = vault_module.IPrereqCheckResult;
const IHostRequester = utils.host_requester.IHostRequester;
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
    host: IHostRequester,

    //
    // Makes a vault that asks the given requester.
    //
    pub fn init(host: IHostRequester) PhoneVault {
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
    fn readItem(self: *PhoneVault, allocator: std.mem.Allocator, key: []const u8) !?[]const u8 {
        const request = try std.json.Stringify.valueAlloc(allocator, .{
            .key = key,
        }, .{});
        const answer = try self.host.call(allocator, "secureStoreGet", request);
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
    fn writeItem(self: *PhoneVault, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        const request = try std.json.Stringify.valueAlloc(allocator, .{
            .key = key,
            .value = value,
        }, .{});
        _ = try self.host.call(allocator, "secureStoreSet", request);
    }

    //
    // Deletes one keychain item. A missing item is not an error.
    //
    fn deleteItem(self: *PhoneVault, allocator: std.mem.Allocator, key: []const u8) !void {
        const request = try std.json.Stringify.valueAlloc(allocator, .{
            .key = key,
        }, .{});
        _ = try self.host.call(allocator, "secureStoreDelete", request);
    }

    //
    // The name of every keychain item.
    //
    fn readKeys(self: *PhoneVault, allocator: std.mem.Allocator) ![]const []const u8 {
        const answer = try self.host.call(allocator, "secureStoreKeys", "null");
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
    //
    pub fn get(self: *PhoneVault, allocator: std.mem.Allocator, io: std.Io, name: []const u8) !?ISecret {
        _ = io;
        const value = try self.readItem(allocator, try std.mem.concat(allocator, u8, &.{ SECRET_VALUE_KEY_PREFIX, name })) orelse {
            return null;
        };
        const secret_type = try self.readItem(allocator, try std.mem.concat(allocator, u8, &.{ SECRET_TYPE_KEY_PREFIX, name })) orelse {
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
        _ = io;
        try self.writeItem(allocator, try std.mem.concat(allocator, u8, &.{ SECRET_VALUE_KEY_PREFIX, secret.name }), secret.value);
        try self.writeItem(allocator, try std.mem.concat(allocator, u8, &.{ SECRET_TYPE_KEY_PREFIX, secret.name }), secret.type);
    }

    //
    // Returns every secret, starting from the type items.
    //
    pub fn list(self: *PhoneVault, allocator: std.mem.Allocator, io: std.Io) ![]ISecret {
        var secrets: std.ArrayList(ISecret) = .empty;
        for (try self.readKeys(allocator)) |key| {
            if (!std.mem.startsWith(u8, key, SECRET_TYPE_KEY_PREFIX)) {
                continue;
            }
            // (A secret deleted since the keys were read is skipped.)
            const secret = try self.get(allocator, io, key[SECRET_TYPE_KEY_PREFIX.len..]) orelse {
                continue;
            };
            try secrets.append(allocator, secret);
        }
        return secrets.items;
    }

    //
    // Deletes a secret by name. The type goes first, so the secret leaves the list before its value goes.
    //
    pub fn delete(self: *PhoneVault, allocator: std.mem.Allocator, io: std.Io, name: []const u8) !void {
        _ = io;
        try self.deleteItem(allocator, try std.mem.concat(allocator, u8, &.{ SECRET_TYPE_KEY_PREFIX, name }));
        try self.deleteItem(allocator, try std.mem.concat(allocator, u8, &.{ SECRET_VALUE_KEY_PREFIX, name }));
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
