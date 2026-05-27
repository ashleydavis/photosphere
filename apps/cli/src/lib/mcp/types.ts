import type { IAsset } from "api";
import type { IBsonCollection, IBsonDatabase } from "bdb";
import type { IStorage } from "storage";
import type { IUuidGenerator, ITimestampProvider } from "utils";
import type { IBaseCommandOptions } from "../init-cmd";

//
// In-process handle to the currently open database. Replaced when the model calls
// `open_database`, cleared when it calls `close_database`.
//
export interface ICurrentDatabase {
    //
    // Resolved path or URI of the open database (after name lookup).
    //
    databasePath: string;

    //
    // Encryption key name passed when the database was opened (if any).
    //
    encryptionKey?: string;

    //
    // Asset storage for the open database.
    //
    assetStorage: IStorage;

    //
    // Metadata collection over the open database.
    //
    metadataCollection: IBsonCollection<IAsset>;

    //
    // BSON database handle, used by the asset-query helpers.
    //
    bsonDatabase: IBsonDatabase;
}

//
// Per-process state and dependencies shared by every MCP tool implementation. Each tool
// registers a closure over this context so it can read/write the open-database handle
// and resolve common services without globals.
//
export interface IMcpToolContext {
    //
    // Returns the currently open database, or undefined when none is open.
    //
    getDatabase(): ICurrentDatabase | undefined;

    //
    // Replaces the open database with a new one (called by open_database).
    //
    setDatabase(database: ICurrentDatabase): void;

    //
    // Drops the open database (called by close_database).
    //
    clearDatabase(): void;

    //
    // UUID generator for database operations.
    //
    uuidGenerator: IUuidGenerator;

    //
    // Timestamp provider for database operations.
    //
    timestampProvider: ITimestampProvider;

    //
    // Session identifier used for write lock tracking.
    //
    sessionId: string;

    //
    // Command-line options the `psi mcp` command was invoked with. Used as the base when
    // open_database synthesises the options passed to loadDatabase.
    //
    options: IBaseCommandOptions;
}
