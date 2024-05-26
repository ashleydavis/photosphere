import { IDatabases } from "../databases";
import { openDatabase } from "./indexeddb";
import { IIndexeddbDatabase, IndexeddbDatabase } from "./indexeddb-database";

//
// Configures a database.
//
export interface IDatabaseConfiguration {
    //
    // The names of the collections in the database.
    //
    collectionNames: string[];

    //
    // The version number of the database.
    //
    versionNumber: number;
}

//
// Look up database configurations by name.
//
export interface IDatabaseConfigurations {
    [databaseName: string]: IDatabaseConfiguration;
}

export interface IIndexeddbDatabases extends IDatabases {
    //
    // Gets a database by name.
    //   
    database(databaseName: string): IIndexeddbDatabase;
}

export class IndexeddbDatabases implements IIndexeddbDatabases {

    private dbCache = new Map<string, IDBDatabase>();

    constructor(private databaseConfigurations: IDatabaseConfigurations, private defaultConfigurationName: string) {
    }

    // 
    // Shutdown all cached database connections.
    //
    shutdown() {
        for (const db of this.dbCache.values()) {
            db.close();
        }

        this.dbCache.clear();
    }
    
    //
    // Gets a database by name.
    //   
    database(databaseName: string): IIndexeddbDatabase {
        return new IndexeddbDatabase(() => this.openDatabase(databaseName));
    }

    //
    // Opens a particular database.
    //
    private async openDatabase(databaseName: string): Promise<IDBDatabase> {
        if (!this.dbCache) {
            throw new Error(`Database cache not initialised.`);
        }
        
        let db = this.dbCache.get(databaseName);
        if (db) {
            return db;
        }

        const databaseNameParts = databaseName.split("-");
        if (databaseNameParts.length === 0) {
            throw new Error(`Invalid database name: "${databaseName}"`);
        }
        const baseDatabaseName = databaseNameParts[0];
        const databaseConfiguration = this.databaseConfigurations[databaseName] || this.databaseConfigurations[baseDatabaseName] || this.databaseConfigurations[this.defaultConfigurationName];
        if (!databaseConfiguration) {
            throw new Error(`No configuration for database: "${databaseName}" (${baseDatabaseName})`);
        }

        db = await openDatabase(`photosphere-${databaseName}`, databaseConfiguration.versionNumber, databaseConfiguration.collectionNames);
        this.dbCache.set(databaseName, db);
        return db;
    }
}
