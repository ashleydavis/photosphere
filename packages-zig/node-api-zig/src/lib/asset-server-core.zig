const std = @import("std");
const ziggy = @import("ziggy");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
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
    nativeCaller: ?utils.native_caller.INativeCaller,
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
        serveAsset: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, thread_arena: std.mem.Allocator, io: std.Io, assetId: []const u8, assetType: []const u8, databasePath: []const u8) anyerror!IReadStream,

        // Writes raw bytes for one asset variant into a database directory from a byte stream.
        writeAsset: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, assetId: []const u8, assetType: []const u8, databasePath: []const u8, contentType: ?[]const u8, inputStream: *std.Io.Reader, contentLength: ?u64) anyerror!void,

        // Applies metadata operations to one or more on-disk databases.
        applyDatabaseOps: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, ops: []const IDatabaseOp) anyerror!void,
    };

    //
    // Loads one asset variant (thumb | display | asset) from a database directory and returns it as a byte stream (to be destroyed
    // with IReadStream.destroy).
    //
    pub fn serveAsset(self: IAssetServerCore, allocator: std.mem.Allocator, thread_arena: std.mem.Allocator, io: std.Io, assetId: []const u8, assetType: []const u8, databasePath: []const u8) anyerror!IReadStream {
        return self.vtable.serveAsset(self.ptr, allocator, thread_arena, io, assetId, assetType, databasePath);
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
// (Zig: the cache and the storages in it are allocated with the arena serveAsset is given for them, which lives as long as the thread
// that owns the core, because the storages outlive the request that made them. A core is used by one thread: the asset server gives
// each of its connection threads a core of its own. The core is allocated with that thread's allocator, which init and deinit are
// given.)
//
pub const AssetServerCore = struct {
    // UUID generator used when applying database ops.
    uuidGenerator: IUuidGenerator,

    // Timestamp provider used when applying database ops.
    timestampProvider: ITimestampProvider,

    // Write-lock owner for write/apply operations.
    sessionId: []const u8,

    // Reaches the phone's keychain for the credentials of a database, or null where there is no phone shell.
    nativeCaller: ?utils.native_caller.INativeCaller,

    // Cache of lazy database storage instances keyed by database path.
    storageCache: std.StringHashMapUnmanaged(IStorage),

    // The generators of a core made with createOwnAssetServerCore, which its uuidGenerator and timestampProvider point at, or null.
    ownGenerators: ?*OwnGenerators,

    //
    // Creates the core, allocated with the owning thread's allocator. The options' generators must stay valid for the life of the
    // core.
    //
    pub fn init(allocator: std.mem.Allocator, options: IAssetServerCoreOptions) !*AssetServerCore {
        const self = try allocator.create(AssetServerCore);
        self.* = .{
            .uuidGenerator = options.uuidGenerator,
            .timestampProvider = options.timestampProvider,
            .sessionId = try allocator.dupe(u8, options.sessionId),
            .nativeCaller = options.nativeCaller,
            .storageCache = .empty,
            .ownGenerators = null,
        };
        return self;
    }

    //
    // Frees the core, with the allocator init was given. The storages it cached are freed with the arena they were made with.
    //
    pub fn deinit(self: *AssetServerCore, allocator: std.mem.Allocator) void {
        allocator.free(self.sessionId);
        if (self.ownGenerators) |generators| {
            allocator.destroy(generators);
        }
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
    // Returns a cached lazy storage instance for the given database path, creating one if needed with the arena of the thread that
    // owns the core.
    //
    fn getAssetStorage(self: *AssetServerCore, thread_arena: std.mem.Allocator, io: std.Io, databasePath: []const u8) !IStorage {
        if (self.storageCache.get(databasePath)) |cached| {
            return cached;
        }
        const credentials = try resolve_storage_credentials.resolveStorageCredentials(thread_arena, io, databasePath, null, null, self.nativeCaller);
        const loadedKeys = try encryption.key_utils.loadEncryptionKeysFromPem(thread_arena, credentials.encryptionKeyPems);
        const storage = try media_file_database.createLazyDatabaseStorage(thread_arena, io, databasePath, credentials.s3Config, loadedKeys.options, self.nativeCaller);
        try self.storageCache.put(thread_arena, try thread_arena.dupe(u8, databasePath), storage);
        return storage;
    }

    //
    // Loads one asset variant (thumb | display | asset) from a database directory and returns it as a byte stream.
    //
    pub fn serveAsset(self: *AssetServerCore, allocator: std.mem.Allocator, thread_arena: std.mem.Allocator, io: std.Io, assetId: []const u8, assetType: []const u8, databasePath: []const u8) !IReadStream {
        const assetStorage = try self.getAssetStorage(thread_arena, io, databasePath);
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
        try apply_database_ops.applyDatabaseOps(allocator, io, self.uuidGenerator, self.timestampProvider, self.sessionId, ops, self.nativeCaller);
    }

    //
    // The IAssetServerCore.VTable.serveAsset of this core.
    //
    fn serveAssetErased(ptr: *anyopaque, allocator: std.mem.Allocator, thread_arena: std.mem.Allocator, io: std.Io, assetId: []const u8, assetType: []const u8, databasePath: []const u8) anyerror!IReadStream {
        const self: *AssetServerCore = @ptrCast(@alignCast(ptr));
        return self.serveAsset(allocator, thread_arena, io, assetId, assetType, databasePath);
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
pub fn createAssetServerCore(allocator: std.mem.Allocator, options: IAssetServerCoreOptions) !*AssetServerCore {
    return AssetServerCore.init(allocator, options);
}

//
// What a core made with createOwnAssetServerCore keeps for itself: its generators, the test ones when NODE_ENV is "testing", as a
// worker's are, and otherwise the random and real ones.
//
pub const OwnGenerators = struct {
    // Makes random ids.
    randomUuids: utils.random_uuid_generator.RandomUuidGenerator = .{},
    // Makes the ids of a test run, or null outside one.
    testUuids: ?node_utils.test_uuid_generator.TestUuidGenerator = null,
    // Gives the time.
    timestamps: utils.timestamp_provider.TimestampProvider = .{},
    // Gives the time of a test run.
    testTimestamps: node_utils.test_timestamp_provider.TestTimestampProvider = .{},
};

//
// Creates a core with generators of its own, for one thread of a server that gives each of its threads a core (see asset-server.zig).
// The core reaches the keychain through the native app's callbacks the thread was given, the thread calling the native app itself, when
// it was given them and the native app has a host request callback. They must outlive the core.
//
pub fn createOwnAssetServerCore(allocator: std.mem.Allocator, sessionId: []const u8, nativeCallbacks: ?*const ziggy.core.NativeCallbacks) !*AssetServerCore {
    const generators = try allocator.create(OwnGenerators);
    errdefer allocator.destroy(generators);
    generators.* = .{};
    const nativeCaller: ?utils.native_caller.INativeCaller = if (nativeCallbacks) |callbacks| callbacks.nativeCaller() else null;
    const testing = std.mem.eql(u8, node_utils.process_env.getEnv("NODE_ENV") orelse "", "testing");
    if (testing) {
        generators.testUuids = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator);
    }
    const core = try AssetServerCore.init(allocator, .{
        .uuidGenerator = if (generators.testUuids) |*test_uuids| test_uuids.uuidGenerator() else generators.randomUuids.uuidGenerator(),
        .timestampProvider = if (testing) generators.testTimestamps.timestampProvider() else generators.timestamps.timestampProvider(),
        .sessionId = sessionId,
        .nativeCaller = nativeCaller,
    });
    core.ownGenerators = generators;
    return core;
}
