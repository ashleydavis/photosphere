const std = @import("std");

//
// Represents a secret stored in a vault.
// The type field is a caller-defined string that categorises the secret
// (e.g. "password", "api-key", "private-key", "s3-credentials").
//
pub const ISecret = struct {
    //
    // Unique name that identifies the secret within the vault.
    //
    name: []const u8,

    //
    // Caller-defined category string for the secret.
    // The vault package places no restrictions on this value.
    //
    type: []const u8,

    //
    // The secret value, stored as a plain string.
    // Callers are responsible for serialising structured values (e.g. JSON).
    //
    value: []const u8,
};

//
// Interface for a vault that can store, retrieve, list, and delete secrets.
// Implementations may persist secrets in a local keyring, a password manager,
// an encrypted file, or any other backend.
// Every method takes the caller's allocator (returned memory belongs to it) and io.
//
pub const IVault = struct {
    // Pointer to the implementation.
    ptr: *anyopaque,

    // The implementation's functions.
    vtable: *const VTable,

    //
    // The functions an implementation of IVault provides (same names as the TypeScript interface).
    //
    pub const VTable = struct {
        // Retrieves a secret by name. Returns null if the secret does not exist.
        get: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, name: []const u8) anyerror!?ISecret,

        // Creates or overwrites a secret.
        set: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, secret: ISecret) anyerror!void,

        // Returns all secrets stored in the vault.
        list: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror![]ISecret,

        // Not ported: delete, checkPrereqs (not used by psi replicate or psi verify).
    };

    //
    // Retrieves a secret by name.
    // Returns null if the secret does not exist.
    //
    pub fn get(self: IVault, allocator: std.mem.Allocator, io: std.Io, name: []const u8) anyerror!?ISecret {
        return self.vtable.get(self.ptr, allocator, io, name);
    }

    //
    // Creates or overwrites a secret.
    //
    pub fn set(self: IVault, allocator: std.mem.Allocator, io: std.Io, secret: ISecret) anyerror!void {
        return self.vtable.set(self.ptr, allocator, io, secret);
    }

    //
    // Returns all secrets stored in the vault.
    //
    pub fn list(self: IVault, allocator: std.mem.Allocator, io: std.Io) anyerror![]ISecret {
        return self.vtable.list(self.ptr, allocator, io);
    }
};

//
// Result returned by IVault.checkPrereqs().
//
pub const IPrereqCheckResult = struct {
    //
    // True when all prerequisites are satisfied.
    //
    ok: bool,

    //
    // Human-readable error message when ok is false, null otherwise.
    //
    message: ?[]const u8,
};
