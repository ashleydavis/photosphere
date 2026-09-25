//
// This file has no TypeScript counterpart. TypeScript passes inline arrow functions to retry, such as
// `retry(() => storage.info(fileName))`. utils-zig's retry takes an operation value with a
// `run(self, io)` method instead, so the arrow functions that several files share are defined here.
// Each is a function of the TypeScript arrow function's source text (the Bun toString() that retryOnce puts
// in its timeout message), because the same operation is written with different variable names in
// different places.
//

const std = @import("std");
const storage_zig = @import("storage-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const hash = @import("hash.zig");
const tree = @import("tree.zig");
const IStorage = storage_zig.storage.IStorage;
const IFileInfo = storage_zig.storage.IFileInfo;
const IMerkleTree = merkle_tree_zig.merkle_tree.IMerkleTree;
const Sha256 = std.crypto.hash.sha2.Sha256;

//
// `() => storage.info(fileName)`.
//
pub fn InfoOperation(comptime sourceText: []const u8) type {
    return struct {
        // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
        pub const source = sourceText;

        // Allocates the result.
        allocator: std.mem.Allocator,

        // The storage holding the file.
        storage: IStorage,

        // The file to get information about.
        fileName: []const u8,

        //
        // Gets the file information.
        //
        pub fn run(self: *@This(), io: std.Io) !?IFileInfo {
            return self.storage.info(self.allocator, io, self.fileName);
        }
    };
}

//
// `() => storage.write(fileName, contentType, data)`.
//
pub fn WriteOperation(comptime sourceText: []const u8) type {
    return struct {
        // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
        pub const source = sourceText;

        // Allocates the storage implementation's temporary data.
        allocator: std.mem.Allocator,

        // The storage to write to.
        storage: IStorage,

        // The file to write.
        fileName: []const u8,

        // The content type of the file.
        contentType: ?[]const u8,

        // The contents of the file.
        data: []const u8,

        //
        // Writes the file.
        //
        pub fn run(self: *@This(), io: std.Io) !void {
            return self.storage.write(self.allocator, io, self.fileName, self.contentType, self.data);
        }
    };
}

//
// `async () => computeHash(await storage.readStream(fileName))`.
//
pub fn ComputeStorageHashOperation(comptime sourceText: []const u8) type {
    return struct {
        // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
        pub const source = sourceText;

        // Allocates the storage implementation's temporary data.
        allocator: std.mem.Allocator,

        // The storage to read the file from.
        storage: IStorage,

        // The file to hash.
        fileName: []const u8,

        //
        // Streams the file from storage and hashes it.
        //
        pub fn run(self: *@This(), io: std.Io) ![Sha256.digest_length]u8 {
            const readStream = try self.storage.readStream(self.allocator, io, self.fileName);
            defer readStream.destroy(io);
            return hash.computeHash(readStream.reader());
        }
    };
}

//
// `async () => { const readStream = await sourceStorage.readStream(fileName);
//                 await destStorage.writeStream(fileName, contentType, readStream); }`.
//
pub fn CopyStreamOperation(comptime sourceText: []const u8) type {
    return struct {
        // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
        pub const source = sourceText;

        // Allocates the storage implementations' temporary data.
        allocator: std.mem.Allocator,

        // The storage to copy the file from.
        sourceStorage: IStorage,

        // The storage to copy the file to.
        destStorage: IStorage,

        // The file to copy (the same path in both storages).
        fileName: []const u8,

        // The content type passed to writeStream.
        contentType: ?[]const u8,

        //
        // Streams the file from the source storage to the destination storage.
        //
        pub fn run(self: *@This(), io: std.Io) !void {
            const readStream = try self.sourceStorage.readStream(self.allocator, io, self.fileName);
            defer readStream.destroy(io);
            try self.destStorage.writeStream(self.allocator, io, self.fileName, self.contentType, readStream.reader(), null);
        }
    };
}

//
// `() => merkleTreeExists(storage)`.
//
pub fn MerkleTreeExistsOperation(comptime sourceText: []const u8) type {
    return struct {
        // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
        pub const source = sourceText;

        // Allocates the storage implementation's temporary data.
        allocator: std.mem.Allocator,

        // The database storage.
        storage: IStorage,

        //
        // Checks whether the files tree exists.
        //
        pub fn run(self: *@This(), io: std.Io) !bool {
            return tree.merkleTreeExists(self.allocator, io, self.storage);
        }
    };
}

//
// `() => loadMerkleTree(storage)`.
//
pub fn LoadMerkleTreeOperation(comptime sourceText: []const u8) type {
    return struct {
        // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
        pub const source = sourceText;

        // Allocates the loaded tree.
        allocator: std.mem.Allocator,

        // The database storage.
        storage: IStorage,

        //
        // Loads the files tree.
        //
        pub fn run(self: *@This(), io: std.Io) !?IMerkleTree {
            return tree.loadMerkleTree(self.allocator, io, self.storage);
        }
    };
}

//
// `() => saveMerkleTree(merkleTree, storage)`.
//
pub fn SaveMerkleTreeOperation(comptime sourceText: []const u8) type {
    return struct {
        // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
        pub const source = sourceText;

        // Allocates the rebuilt merkle nodes and the serialized data.
        allocator: std.mem.Allocator,

        // The tree to save.
        merkleTree: *IMerkleTree,

        // The database storage.
        storage: IStorage,

        //
        // Saves the files tree.
        //
        pub fn run(self: *@This(), io: std.Io) !void {
            return tree.saveMerkleTree(self.allocator, io, self.merkleTree, self.storage);
        }
    };
}
