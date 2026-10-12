//
// Writes the app's databases.toml with one test database registered, merged into the file the device already had, for
// run-android.sh, which reads the existing file off the device, runs this and pushes the result back. The fixture is named
// test-<name>, made the most recent database and made the one reopened on launch, so the app starts in it. Every other test-
// entry is removed first, so fixtures do not pile up, and the user's own entries and recents are left as they were. The entry's
// path is the database's full path on the device, because the app opens no relative path against its storage. The file is
// rendered by buildDatabasesConfigToml in node-api, which the app's own write of the file uses.
//
// Usage: bun scripts/write-fixture-databases-config.ts <name> <path> <existing-file> <output-file>
//   <name>           the fixture's name, which the entry is named after (test-<name>)
//   <path>           the full path of the database on the device
//   <existing-file>  the databases.toml the device had, which is empty when it had none
//   <output-file>    where the merged databases.toml is written
//

import { readFileSync, writeFileSync } from "fs";
import { parse as parseToml } from "smol-toml";
import { buildDatabasesConfigToml } from "node-api/src/lib/databases-config.worker";
import { tomlEntryToDatabaseEntry, type ITomlDatabasesConfig } from "node-api/src/lib/databases-config-format";

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
        .map(tomlEntryToDatabaseEntry);
    databases.push(tomlEntryToDatabaseEntry({
        name: fixtureName,
        description: "",
        path: databasePath,
    }));
    const recentDatabaseNames = [
        fixtureName,
        ...(parsed.recent_database_names ?? []).filter(recentName => !recentName.toLowerCase().startsWith("test-")),
    ];
    writeFileSync(outputFile, buildDatabasesConfigToml(databases, recentDatabaseNames, databasePath));
}

main();
