const std = @import("std");
const utils = @import("utils-zig");
const storage_zig = @import("storage-zig");
const encryption = @import("encryption-zig");
const api = @import("api-zig");
const media_file_database = @import("media-file-database.zig");
const resolve_storage_credentials = @import("resolve-storage-credentials.zig");
const apply_database_ops = @import("apply-database-ops.zig");
const IStorage = storage_zig.storage.IStorage;
const IReadStream = storage_zig.storage.IReadStream;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const ITimestampProvider = utils.timestamp_provider.ITimestampProvider;
const IDatabaseOp = api.database_op.IDatabaseOp;

//
// Options for creating the transport-agnostic asset server core.
//
pub const IAssetServerCoreOptions = struct {
    // UUID generator used when applying database ops.
    uuidGenerator: IUuidGenerator,

    // Timestamp provider used when applying database ops.
    timestampProvider: ITimestampProvider,

    // Write-lock owner for write/apply operations (see acquireWriteLock).
    sessionId: []const u8,

    // Reaches the phone's keychain for the credentials of a database, or null where there is no phone shell.
    hostRequester: ?utils.host_requester.IHostRequester,
};

//
// The transport-agnostic asset server core. Holds the storage cache and exposes the
// serve/write/apply operations the HTTP routes call, with no knowledge of HTTP.
// The same core is reused by the HTTP wiring of the REST API and by the asset-server task.
// (Zig: an interface with a pointer and a table of functions, so the routes can be run against another core. Every function may
// be called from many threads at once. The allocator given to a function is the caller's, and is freed by the caller.)
//
pub const IAssetServerCore = struct {
    // Pointer to the implementation.
    ptr: *anyopaque,

    // The implementation's functions.
    vtable: *const VTable,

    //
    // The functions an implementation of IAssetServerCore provides.
    //
    pub const VTable = struct {
        // Loads one asset variant (thumb | display | asset) from a database directory and returns it as a byte stream.
        serveAsset: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, assetId: []const u8, assetType: []const u8, databasePath: []const u8) anyerror!IReadStream,

        // Writes raw bytes for one asset variant into a database directory from a byte stream.
        writeAsset: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, assetId: []const u8, assetType: []const u8, databasePath: []const u8, contentType: ?[]const u8, inputStream: *std.Io.Reader, contentLength: ?u64) anyerror!void,

        // Applies metadata operations to one or more on-disk databases.
        applyDatabaseOps: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, ops: []const IDatabaseOp) anyerror!void,
    };

    //
    // Loads one asset variant (thumb | display | asset) from a database directory and returns it as a byte stream (to be destroyed
    // with IReadStream.destroy).
    //
    pub fn serveAsset(self: IAssetServerCore, allocator: std.mem.Allocator, io: std.Io, assetId: []const u8, assetType: []const u8, databasePath: []const u8) anyerror!IReadStream {
        return self.vtable.serveAsset(self.ptr, allocator, io, assetId, assetType, databasePath);
    }

    //
    // Writes raw bytes for one asset variant into a database directory from a byte stream.
    //
    pub fn writeAsset(self: IAssetServerCore, allocator: std.mem.Allocator, io: std.Io, assetId: []const u8, assetType: []const u8, databasePath: []const u8, contentType: ?[]const u8, inputStream: *std.Io.Reader, contentLength: ?u64) anyerror!void {
        return self.vtable.writeAsset(self.ptr, allocator, io, assetId, assetType, databasePath, contentType, inputStream, contentLength);
    }

    //
    // Applies metadata operations to one or more on-disk databases.
    //
    pub fn applyDatabaseOps(self: IAssetServerCore, allocator: std.mem.Allocator, io: std.Io, ops: []const IDatabaseOp) anyerror!void {
        return self.vtable.applyDatabaseOps(self.ptr, allocator, io, ops);
    }
};

//
// The core that createAssetServerCore makes. It owns a cache of lazy database storage instances keyed by database path, so repeated
// reads avoid re-reading the config / merkle-tree files.
// (Zig: the cache lives in an arena of its own, because the storages in it outlive the request that made them, and a lock guards it,
// because requests are served on many threads.)
//
pub const AssetServerCore = struct {
    // Allocates the cache. It must be safe to use from many threads.
    allocator: std.mem.Allocator,

    // Allocates what the cached storages are made of.
    cache_arena: std.heap.ArenaAllocator,

    // The Io the cached storages were made with.
    io: std.Io,

    // UUID generator used when applying database ops.
    uuidGenerator: IUuidGenerator,

    // Timestamp provider used when applying database ops.
    timestampProvider: ITimestampProvider,

    // Write-lock owner for write/apply operations.
    sessionId: []const u8,

    // Reaches the phone's keychain for the credentials of a database, or null where there is no phone shell.
    hostRequester: ?utils.host_requester.IHostRequester,

    // Cache of lazy database storage instances keyed by database path.
    storageCache: std.StringHashMapUnmanaged(IStorage),

    // Guards the cache.
    mutex: std.Io.Mutex,

    //
    // Creates the core. The allocator must be safe to use from many threads, and the options' generators must stay valid for the life
    // of the core.
    //
    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: IAssetServerCoreOptions) !*AssetServerCore {
        const self = try allocator.create(AssetServerCore);
        self.* = .{
            .allocator = allocator,
            .cache_arena = std.heap.ArenaAllocator.init(allocator),
            .io = io,
            .uuidGenerator = options.uuidGenerator,
            .timestampProvider = options.timestampProvider,
            .sessionId = try allocator.dupe(u8, options.sessionId),
            .hostRequester = options.hostRequester,
            .storageCache = .empty,
            .mutex = .init,
        };
        return self;
    }

    //
    // Frees the core and the storages it cached.
    //
    pub fn deinit(self: *AssetServerCore) void {
        const allocator = self.allocator;
        self.storageCache.deinit(allocator);
        self.cache_arena.deinit();
        allocator.free(self.sessionId);
        allocator.destroy(self);
    }

    //
    // Gets the IAssetServerCore interface for this core.
    //
    pub fn assetServerCore(self: *AssetServerCore) IAssetServerCore {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // The IAssetServerCore functions of this core.
    //
    const vtable: IAssetServerCore.VTable = .{
        .serveAsset = serveAssetErased,
        .writeAsset = writeAssetErased,
        .applyDatabaseOps = applyDatabaseOpsErased,
    };

    //
    // Returns a cached lazy storage instance for the given database path, creating one if needed.
    //
    fn getAssetStorage(self: *AssetServerCore, io: std.Io, databasePath: []const u8) !IStorage {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.storageCache.get(databasePath)) |cached| {
            return cached;
        }
        const arena = self.cache_arena.allocator();
        const credentials = try resolve_storage_credentials.resolveStorageCredentials(arena, io, databasePath, null, null, self.hostRequester);
        const loadedKeys = try encryption.key_utils.loadEncryptionKeysFromPem(arena, credentials.encryptionKeyPems);
        const storage = try media_file_database.createLazyDatabaseStorage(arena, io, databasePath, credentials.s3Config, loadedKeys.options, self.hostRequester);
        try self.storageCache.put(self.allocator, try arena.dupe(u8, databasePath), storage);
        return storage;
    }

    //
    // Loads one asset variant (thumb | display | asset) from a database directory and returns it as a byte stream.
    //
    pub fn serveAsset(self: *AssetServerCore, allocator: std.mem.Allocator, io: std.Io, assetId: []const u8, assetType: []const u8, databasePath: []const u8) !IReadStream {
        const assetStorage = try self.getAssetStorage(io, databasePath);
        return try media_file_database.streamAsset(allocator, io, assetStorage, assetId, assetType);
    }

    //
    // Writes raw bytes for one asset variant into a database directory from a byte stream.
    //
    pub fn writeAsset(self: *AssetServerCore, allocator: std.mem.Allocator, io: std.Io, assetId: []const u8, assetType: []const u8, databasePath: []const u8, contentType: ?[]const u8, inputStream: *std.Io.Reader, contentLength: ?u64) !void {
        const created = try storage_zig.storage_factory.createStorage(allocator, io, databasePath, null, null);
        try media_file_database.writeAssetStream(allocator, io, created.storage, created.rawStorage, self.sessionId, assetId, assetType, contentType, inputStream, contentLength);
    }

    //
    // Applies metadata operations to one or more on-disk databases.
    //
    pub fn applyDatabaseOps(self: *AssetServerCore, allocator: std.mem.Allocator, io: std.Io, ops: []const IDatabaseOp) !void {
        try apply_database_ops.applyDatabaseOps(allocator, io, self.uuidGenerator, self.timestampProvider, self.sessionId, ops, self.hostRequester);
    }

    //
    // The IAssetServerCore.VTable.serveAsset of this core.
    //
    fn serveAssetErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, assetId: []const u8, assetType: []const u8, databasePath: []const u8) anyerror!IReadStream {
        const self: *AssetServerCore = @ptrCast(@alignCast(ptr));
        return self.serveAsset(allocator, io, assetId, assetType, databasePath);
    }

    //
    // The IAssetServerCore.VTable.writeAsset of this core.
    //
    fn writeAssetErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, assetId: []const u8, assetType: []const u8, databasePath: []const u8, contentType: ?[]const u8, inputStream: *std.Io.Reader, contentLength: ?u64) anyerror!void {
        const self: *AssetServerCore = @ptrCast(@alignCast(ptr));
        return self.writeAsset(allocator, io, assetId, assetType, databasePath, contentType, inputStream, contentLength);
    }

    //
    // The IAssetServerCore.VTable.applyDatabaseOps of this core.
    //
    fn applyDatabaseOpsErased(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, ops: []const IDatabaseOp) anyerror!void {
        const self: *AssetServerCore = @ptrCast(@alignCast(ptr));
        return self.applyDatabaseOps(allocator, io, ops);
    }
};

//
// Creates the transport-agnostic asset server core. The returned object owns a cache of lazy
// database storage instances keyed by database path, so repeated reads avoid re-reading the
// config / merkle-tree files. The HTTP layer calls these methods; their behaviour is identical regardless of
// how the request arrived.
// (Zig: free it with `deinit`.)
//
pub fn createAssetServerCore(allocator: std.mem.Allocator, io: std.Io, options: IAssetServerCoreOptions) !*AssetServerCore {
    return AssetServerCore.init(allocator, io, options);
}
