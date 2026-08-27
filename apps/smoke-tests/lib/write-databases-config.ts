//
// Writes a databases.toml for the mobile smoke tests.
//
// A mobile test establishes its configured-databases and recent-databases state the way a desktop
// test does: by writing the config file before the app starts. The app has no filesystem access of
// its own, so the harness renders the file here on the host and the platform helper copies it into
// the device's storage sandbox (android_seed_databases_config / ios_seed_databases_config).
//
// The rendering is buildDatabasesConfigToml in node-api, the same function the app writes the file
// through on device, so the harness and the app cannot drift on the format.
//
// Usage: DATABASES='<json array>' RECENT='<json array of names>' bun write-databases-config.ts <output-file>
//
// Importing node-api here is what pins this package's tsconfig `lib` to ES2022 (plus DOM, which the
// implicit ES2020 lib used to bring in): node-api's error types use the ES2022 Error `cause` option.

import { writeFileSync } from "fs";
import { buildDatabasesConfigToml } from "node-api/src/lib/databases-config.worker";
import type { IDatabaseEntry } from "node-api/src/lib/databases-config-format";

//
// Parses one of the two JSON environment variables, defaulting to an empty list when it is unset or
// empty. A malformed value throws rather than being treated as empty: a test that meant to seed
// state and silently seeded none would fail later, somewhere unrelated.
//
function parseJsonList<ItemT>(variableName: string): ItemT[] {
    const raw = process.env[variableName];
    if (!raw || raw.trim().length === 0) {
        return [];
    }
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) {
        throw new Error(`${variableName} must be a JSON array, got: ${raw}`);
    }
    return parsed as ItemT[];
}

//
// Renders the config from the DATABASES, RECENT and LAST_DATABASE environment variables into the
// file named by the last argument.
//
function main(): void {
    const outputPath = process.argv[process.argv.length - 1];
    if (!outputPath || outputPath.endsWith("write-databases-config.ts")) {
        throw new Error("usage: DATABASES=<json> RECENT=<json> [LAST_DATABASE=<path>] write-databases-config.ts <output-file>");
    }

    // Descriptions are optional at the call site (a smoke test seeding a name and a path is the
    // common case), but the entry type requires one, so an absent description becomes empty.
    const databases = parseJsonList<IDatabaseEntry>("DATABASES").map(entry => ({
        ...entry,
        description: entry.description ?? "",
    }));
    const recentDatabaseNames = parseJsonList<string>("RECENT");

    // Seeds the database the app opens on start. A test that wants none leaves it unset, which is
    // the state of a device where no database has ever been opened.
    const rawLastDatabase = process.env.LAST_DATABASE;
    const lastDatabase = rawLastDatabase && rawLastDatabase.trim().length > 0 ? rawLastDatabase : undefined;

    writeFileSync(outputPath, buildDatabasesConfigToml(databases, recentDatabaseNames, lastDatabase));
}

main();
