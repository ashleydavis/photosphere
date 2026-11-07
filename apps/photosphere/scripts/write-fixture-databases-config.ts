//
// Writes the app's databases.toml with one test database registered, merged into the file the device already had, and the
// databases section of its state.yaml with that database made the most recent and the one reopened on launch, merged into the
// state.yaml the device already had. run-android.sh reads the existing files off the device, runs this and pushes the results back;
// run-ios.sh copies them out of the simulator's container and has this write straight back into it. The fixture is named
// test-<name>, so the app starts in it. Every other test- entry and test- recent is removed first, so fixtures do not pile up, and
// the user's own entries, their recents and every other section of state.yaml are kept as they were. The entry's path is the
// database's full path on the device, because the app opens no relative path against its storage.
//
// Usage: bun scripts/write-fixture-databases-config.ts <name> <path> <existing-databases> <databases-output> <existing-state> <state-output>
//   <name>                the fixture's name, which the entry is named after (test-<name>)
//   <path>                the full path of the database on the device
//   <existing-databases>  the databases.toml the device had, which is empty when it had none
//   <databases-output>    where the merged databases.toml is written
//   <existing-state>      the state.yaml the device had, which is empty when it had none
//   <state-output>        where the merged state.yaml is written
//

import { readFileSync, writeFileSync } from "fs";
import { parse as parseToml, stringify as stringifyToml } from "smol-toml";
import yaml from "js-yaml";
import { databaseEntryToToml, tomlEntryToDatabaseEntry, type ITomlDatabasesConfig } from "node-api/src/lib/databases-config-format";

//
// The prefix that marks a database entry or a recent name as a test fixture.
//
const TEST_PREFIX = "test-";

//
// The databases section of state.yaml, as it is written on disk.
//
interface IYamlDatabasesState {
    // Names of the databases opened most recently, most recent first.
    recent_names?: string[];

    // Path of the database to reopen on launch.
    last_opened_path?: string;
}

//
// Reads a file's text and parses it with the parser given, or returns an empty object when the file is empty.
//
function parseOrEmpty(fileName: string, parse: (text: string) => unknown): Record<string, unknown> {
    const text = readFileSync(fileName, "utf8");
    if (text.trim().length === 0) {
        return {};
    }
    const parsed = parse(text);
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
        throw new Error(`${fileName} does not hold a mapping, so it is not written over.`);
    }
    return parsed as Record<string, unknown>;
}

//
// Reads the arguments, merges the fixture into the existing files and writes the results.
//
function main(): void {
    const [name, databasePath, existingDatabasesFile, databasesOutputFile, existingStateFile, stateOutputFile] = process.argv.slice(2);
    if (!name || !databasePath || !existingDatabasesFile || !databasesOutputFile || !existingStateFile || !stateOutputFile) {
        throw new Error("Usage: write-fixture-databases-config.ts <name> <path> <existing-databases> <databases-output> <existing-state> <state-output>");
    }

    const fixtureName = `${TEST_PREFIX}${name}`;

    const parsedDatabases = parseOrEmpty(existingDatabasesFile, parseToml) as ITomlDatabasesConfig;
    const databases = (parsedDatabases.databases ?? [])
        .filter(entry => !(entry.name ?? "").toLowerCase().startsWith(TEST_PREFIX))
        .map(tomlEntryToDatabaseEntry);
    databases.push(tomlEntryToDatabaseEntry({
        name: fixtureName,
        description: "",
        path: databasePath,
    }));
    writeFileSync(databasesOutputFile, stringifyToml({
        databases: databases.map(databaseEntryToToml),
    }) + "\n");

    const state = parseOrEmpty(existingStateFile, text => yaml.load(text));
    const existingSection = (state.databases ?? {}) as IYamlDatabasesState;
    const databasesState: IYamlDatabasesState = {
        recent_names: [
            fixtureName,
            ...(existingSection.recent_names ?? []).filter(recentName => !recentName.toLowerCase().startsWith(TEST_PREFIX)),
        ],
        last_opened_path: databasePath,
    };
    state.databases = databasesState;
    writeFileSync(stateOutputFile, yaml.dump(state));
}

main();
