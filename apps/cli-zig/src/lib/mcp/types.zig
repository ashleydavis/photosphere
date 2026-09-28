const std = @import("std");
const utils = @import("utils-zig");
const storage_zig = @import("storage-zig");
const bdb = @import("bdb-zig");
const init_cmd = @import("../init-cmd.zig");
const IStorage = storage_zig.storage.IStorage;
const IBsonCollection = bdb.collection.IBsonCollection;
const IBsonDatabase = bdb.database.BsonDatabase;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const ITimestampProvider = utils.timestamp_provider.ITimestampProvider;
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;

//
// In-process handle to the currently open database. Replaced when the model calls
// `open_database`, cleared when it calls `close_database`.
//
pub const ICurrentDatabase = struct {
    //
    // Resolved path or URI of the open database (after name lookup).
    //
    databasePath: []const u8,

    //
    // Encryption key name passed when the database was opened (if any).
    //
    encryptionKey: ?[]const u8 = null,

    //
    // Asset storage for the open database.
    //
    assetStorage: IStorage,

    //
    // Metadata collection over the open database.
    //
    metadataCollection: *IBsonCollection,

    //
    // BSON database handle, used by the asset-query helpers.
    //
    bsonDatabase: *IBsonDatabase,
};

//
// Per-process state and dependencies shared by every MCP tool implementation. Each tool
// registers a closure over this context so it can read/write the open-database handle
// and resolve common services without globals.
// (Zig: the tools are registered with a pointer to this context. The open database, which TypeScript keeps in a
// variable of mcpCommand that getDatabase, setDatabase and clearDatabase close over, is a field here.)
//
pub const IMcpToolContext = struct {
    //
    // The currently open database, or null when none is open.
    //
    currentDatabase: ?ICurrentDatabase = null,

    //
    // UUID generator for database operations.
    //
    uuidGenerator: IUuidGenerator,

    //
    // Timestamp provider for database operations.
    //
    timestampProvider: ITimestampProvider,

    //
    // Session identifier used for write lock tracking.
    //
    sessionId: []const u8,

    //
    // Command-line options the `psi mcp` command was invoked with. Used as the base when
    // open_database synthesises the options passed to loadDatabase.
    //
    options: IBaseCommandOptions,

    //
    // Allocates what outlives a tool call: the open database, and what the imports and verifications hand to the
    // tasks and termination callbacks they start. (No TypeScript counterpart: JavaScript is garbage collected.)
    //
    allocator: std.mem.Allocator,

    //
    // Returns the currently open database, or null when none is open.
    //
    pub fn getDatabase(self: *const IMcpToolContext) ?ICurrentDatabase {
        return self.currentDatabase;
    }

    //
    // Replaces the open database with a new one (called by open_database).
    //
    pub fn setDatabase(self: *IMcpToolContext, database: ICurrentDatabase) void {
        self.currentDatabase = database;
    }

    //
    // Drops the open database (called by close_database).
    //
    pub fn clearDatabase(self: *IMcpToolContext) void {
        self.currentDatabase = null;
    }
};
