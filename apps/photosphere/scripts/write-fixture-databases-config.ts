//
// Writes the app's databases.toml with one test database registered, merged into the file the device already had, for
// run-android.sh, which reads the existing file off the device, runs this and pushes the result back. The fixture is named
// test-<name>, made the most recent database and made the one reopened on launch, so the app starts in it. Every other test-
// entry is removed first, so fixtures do not pile up, and the user's own entries and recents are left as they were. The entry's
// path is the database's full path on the device, because the app opens no relative path against its storage. Each entry is
// written with its keys in the order the app's own writer uses (buildDatabasesConfigToml in
// packages-zig/node-api-zig/src/lib/databases-config.worker.zig), so a merged file reads the same as one the app wrote.
//
// Usage: bun scripts/write-fixture-databases-config.ts <name> <path> <existing-file> <output-file>
//   <name>           the fixture's name, which the entry is named after (test-<name>)
//   <path>           the full path of the database on the device
//   <existing-file>  the databases.toml the device had, which is empty when it had none
//   <output-file>    where the merged databases.toml is written
//

import { readFileSync, writeFileSync } from "fs";
import { parse as parseToml, stringify as stringifyToml } from "smol-toml";

//
// One database entry as databases.toml stores it.
//
interface ITomlDatabaseEntry {
    // The name the database is listed under.
    name?: string;

    // What the user wrote about the database.
    description?: string;

    // Where the database is.
    path?: string;

    // The database this one syncs with.
    origin?: string;

    // The vault secret holding the S3 credentials.
    s3_key?: string;

    // The vault secret holding the encryption key.
    encryption_key?: string;

    // The vault secret holding the geocoding API key.
    geocoding_key?: string;
}

//
// The parts of databases.toml this script reads and writes.
//
interface ITomlDatabasesConfig {
    // The names of the databases opened most recently, most recent first.
    recent_database_names?: string[];

    // Every database the app lists.
    databases?: ITomlDatabaseEntry[];

    // The path of the database the app reopens on launch.
    last_database?: string;
}

//
// Copies an entry with its keys in the order the app's writer uses, leaving out the optional keys it does not have.
//
export function orderEntryKeys(entry: ITomlDatabaseEntry): ITomlDatabaseEntry {
    const ordered: ITomlDatabaseEntry = {
        name: entry.name ?? "",
        description: entry.description ?? "",
        path: entry.path ?? "",
    };
    if (entry.origin !== undefined) {
        ordered.origin = entry.origin;
    }
    if (entry.s3_key !== undefined) {
        ordered.s3_key = entry.s3_key;
    }
    if (entry.encryption_key !== undefined) {
        ordered.encryption_key = entry.encryption_key;
    }
    if (entry.geocoding_key !== undefined) {
        ordered.geocoding_key = entry.geocoding_key;
    }
    return ordered;
}

//
// Reads the arguments, merges the fixture into the existing config and writes the result.
//
function main(): void {
    const [name, databasePath, existingFile, outputFile] = process.argv.slice(2);
    if (!name || !databasePath || !existingFile || !outputFile) {
        throw new Error("Usage: write-fixture-databases-config.ts <name> <path> <existing-file> <output-file>");
    }

    const existingToml = readFileSync(existingFile, "utf8");
    const parsed = existingToml.trim().length > 0 ? parseToml(existingToml) as ITomlDatabasesConfig : {};
    const fixtureName = `test-${name}`;
    const databases = (parsed.databases ?? [])
        .filter(entry => !(entry.name ?? "").toLowerCase().startsWith("test-"))
        .map(orderEntryKeys);
    databases.push(orderEntryKeys({
        name: fixtureName,
        description: "",
        path: databasePath,
    }));
    const recentDatabaseNames = [
        fixtureName,
        ...(parsed.recent_database_names ?? []).filter(recentName => !recentName.toLowerCase().startsWith("test-")),
    ];
    const merged: ITomlDatabasesConfig = {
        recent_database_names: recentDatabaseNames,
        databases,
        last_database: databasePath,
    };
    writeFileSync(outputFile, stringifyToml(merged) + "\n");
}

main();
