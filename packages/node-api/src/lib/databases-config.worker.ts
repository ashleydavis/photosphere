//
// Reads and writes a databases.toml as a background task.
//
// Nothing here is platform-specific: the handlers take the path of the config and reach it through
// the storage layer, the same one the databases themselves are read through. They exist because a
// caller with no filesystem access needs a way to reach the file, which is the mobile WebView's
// situation: it holds the database list but cannot open a file, so its reads and writes run in the
// embedded worker. Desktop has no such restriction and calls databases-config.ts directly.
//
// The on-disk shape comes from databases-config-format.ts, the same module desktop converts through,
// so a file written by either platform is readable by the other by construction rather than by two
// definitions being kept in step by hand.
//

import { parse as parseToml, stringify as stringifyToml } from "smol-toml";
import type { ITaskContext } from "task-queue";
import { FileStorage } from "storage";
import { databaseEntryToToml, tomlEntryToDatabaseEntry, type IDatabaseEntry, type ITomlDatabaseEntry, type ITomlDatabasesConfig } from "./databases-config-format";

//
// Input for the read-databases-config task.
//
export interface IReadDatabasesConfigData {
    // Sandbox-relative path of databases.toml.
    configPath: string;
}

//
// Input for the write-databases-config task.
//
export interface IWriteDatabasesConfigData {
    // Sandbox-relative path of databases.toml.
    configPath: string;

    // The configured databases to write.
    databases: IDatabaseEntry[];

    // The recently opened database names to write, most recent first.
    recentDatabaseNames: string[];
}

//
// Result of the read-databases-config task.
//
export interface IReadDatabasesConfigResult {
    // The configured databases, empty when the file does not exist yet.
    databases: IDatabaseEntry[];

    // The recently opened database names, empty when the file does not exist yet.
    recentDatabaseNames: string[];
}

//
// Handler for the read-databases-config task.
//
// A missing file returns empty lists, which is the state of a device that has registered no
// databases, and is what the app starts from on a fresh install.
//
export async function readDatabasesConfigHandler(data: IReadDatabasesConfigData, _context: ITaskContext): Promise<IReadDatabasesConfigResult> {
    if (!data.configPath) {
        throw new Error("configPath is required");
    }

    const storage = new FileStorage("fs:");
    if (!await storage.fileExists(data.configPath)) {
        return { databases: [], recentDatabaseNames: [] };
    }

    const contents = await storage.read(data.configPath);
    if (!contents) {
        return { databases: [], recentDatabaseNames: [] };
    }

    const toml = parseToml(contents.toString("utf8")) as ITomlDatabasesConfig;
    const databases = Array.isArray(toml.databases)
        ? toml.databases.map(tomlEntryToDatabaseEntry)
        : [];
    const recentDatabaseNames = Array.isArray(toml.recent_database_names)
        ? toml.recent_database_names
        : [];
    return { databases, recentDatabaseNames };
}

//
// Handler for the write-databases-config task.
//
export async function writeDatabasesConfigHandler(data: IWriteDatabasesConfigData, _context: ITaskContext): Promise<void> {
    if (!data.configPath) {
        throw new Error("configPath is required");
    }

    const contents = buildDatabasesConfigToml(data.databases, data.recentDatabaseNames);
    const storage = new FileStorage("fs:");
    await storage.write(data.configPath, "application/toml", Buffer.from(contents, "utf8"));
}

//
// Prefix marking a database entry as a test fixture rather than one of the user's own.
//
// Entries carrying it are owned by the deploy script: it removes them and rewrites them freely.
// Anything without it is the user's and is never touched.
//
export const TEST_DATABASE_PREFIX = "test-";

//
// Returns true when a name marks a test fixture.
//
function isTestDatabaseName(name: string): boolean {
    return name.toLowerCase().startsWith(TEST_DATABASE_PREFIX);
}

//
// Adds a test database to the TOML text of a databases config, returning the new text.
//
// Used by the deploy script (apps/android-frontend/scripts/write-databases-config.ts) to register a
// fixture it has just copied onto a device, the same way a database is registered in
// ~/.config/photosphere/databases.toml on desktop. It is here, beside the read and write handlers,
// because it has to produce exactly the file they expect.
//
// The entry is named with the test prefix, so it reads as a test database in the app's list. Every
// other test entry is removed first, so old fixtures do not accumulate run after run. The user's own
// entries are never removed, reordered or edited, and neither are their recents.
//
// Malformed TOML throws rather than being replaced: the file being unreadable is exactly when
// overwriting it would destroy a config that cannot be recovered.
//
export function registerDatabaseInConfig(existingToml: string, databasePath: string): string {
    let databases: ITomlDatabaseEntry[] = [];
    let recentDatabaseNames: string[] = [];

    if (existingToml.trim().length > 0) {
        const parsed = parseToml(existingToml) as ITomlDatabasesConfig;
        databases = parsed.databases ?? [];
        recentDatabaseNames = parsed.recent_database_names ?? [];
    }

    databases = databases.filter(entry => !isTestDatabaseName(entry.name ?? ""));
    recentDatabaseNames = recentDatabaseNames.filter(recentName => !isTestDatabaseName(recentName));

    databases.push({ name: TEST_DATABASE_PREFIX + databasePath, description: "", path: databasePath });

    return buildDatabasesConfigToml(databases.map(tomlEntryToDatabaseEntry), recentDatabaseNames);
}

//
// Renders a whole databases config as the TOML text of a databases.toml, returning it rather than
// writing it anywhere.
//
// This is the same rendering writeDatabasesConfigHandler performs before it writes the file, factored
// out so a host-side script can produce a file the handlers read back exactly. The mobile smoke-test
// harness uses it to seed a device's database list from outside the app (see
// apps/smoke-tests/lib/write-databases-config.ts), which is how a mobile test establishes the state
// desktop tests establish by pre-writing ~/.config/photosphere/databases.toml.
//
export function buildDatabasesConfigToml(databases: IDatabaseEntry[], recentDatabaseNames: string[]): string {
    const toml: ITomlDatabasesConfig = {
        recent_database_names: recentDatabaseNames,
        databases: databases.map(databaseEntryToToml),
    };
    return stringifyToml(toml) + "\n";
}
