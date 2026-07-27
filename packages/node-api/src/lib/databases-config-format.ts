//
// The on-disk shape of databases.toml and the conversions between it and the in-memory entry type.
//
// Shared by desktop (databases-config.ts, which owns ~/.config/photosphere/databases.toml) and
// mobile (databases-config.worker.ts, which owns the copy in the app's storage sandbox), so
// there is one definition of the file format rather than one per platform. Nothing here touches the
// filesystem, which is what lets it be bundled into the mobile worker.
//

//
// A database entry stored in databases.toml.
// The name field is the unique (case-insensitive) identifier for each entry.
//
export interface IDatabaseEntry {
    // Human-readable display name.
    name: string;

    // Optional description of this database.
    description: string;

    // Absolute filesystem path (or S3 path) to the database directory.
    path: string;

    // Optional origin string read from .db/config.json; refreshed each time the database is opened.
    origin?: string;

    // Vault secret name for S3 credentials.
    s3Key?: string;

    // Vault secret name for the encryption key pair.
    encryptionKey?: string;

    // Vault secret name for the geocoding API key.
    geocodingKey?: string;
}

//
// TOML on-disk shape for a single database entry (snake_case keys).
//
export interface ITomlDatabaseEntry {
    // Human-readable display name.
    name: string;

    // Optional description of this database.
    description: string;

    // Absolute filesystem path (or S3 path) to the database directory.
    path: string;

    // Optional origin string.
    origin?: string;

    // Vault secret name for S3 credentials.
    s3_key?: string;

    // Vault secret name for the encryption key pair.
    encryption_key?: string;

    // Vault secret name for the geocoding API key.
    geocoding_key?: string;
}

//
// TOML on-disk shape for the databases config file (snake_case keys).
//
export interface ITomlDatabasesConfig {
    // Array of database entries.
    databases?: ITomlDatabaseEntry[];

    // Recently opened database names.
    recent_database_names?: string[];

    // Legacy field — recently opened database paths. Migrated on load.
    recent_database_paths?: string[];
}

//
// Converts a TOML-shaped database entry to the TypeScript IDatabaseEntry type.
//
export function tomlEntryToDatabaseEntry(tomlEntry: ITomlDatabaseEntry): IDatabaseEntry {
    const entry: IDatabaseEntry = {
        name: tomlEntry.name,
        description: tomlEntry.description,
        path: tomlEntry.path,
    };
    if (tomlEntry.origin !== undefined) {
        entry.origin = tomlEntry.origin;
    }
    if (tomlEntry.s3_key !== undefined) {
        entry.s3Key = tomlEntry.s3_key;
    }
    if (tomlEntry.encryption_key !== undefined) {
        entry.encryptionKey = tomlEntry.encryption_key;
    }
    if (tomlEntry.geocoding_key !== undefined) {
        entry.geocodingKey = tomlEntry.geocoding_key;
    }
    return entry;
}

//
// Converts a TypeScript IDatabaseEntry to the TOML on-disk shape.
//
export function databaseEntryToToml(entry: IDatabaseEntry): ITomlDatabaseEntry {
    const tomlEntry: ITomlDatabaseEntry = {
        name: entry.name,
        description: entry.description,
        path: entry.path,
    };
    if (entry.origin !== undefined) {
        tomlEntry.origin = entry.origin;
    }
    if (entry.s3Key !== undefined) {
        tomlEntry.s3_key = entry.s3Key;
    }
    if (entry.encryptionKey !== undefined) {
        tomlEntry.encryption_key = entry.encryptionKey;
    }
    if (entry.geocodingKey !== undefined) {
        tomlEntry.geocoding_key = entry.geocodingKey;
    }
    return tomlEntry;
}

