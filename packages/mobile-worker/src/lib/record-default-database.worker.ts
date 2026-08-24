import type { ITaskContext } from "task-queue";
import { DEFAULT_DATABASE_DISPLAY_NAME } from "api/src/lib/auto-import-mobile";
import { AUTO_IMPORT_CONFIG_PATH, DATABASES_CONFIG_PATH } from "api/src/lib/mobile-config-paths";
import { readAutoImportConfigFile, writeAutoImportConfigHandler } from "node-api/src/lib/auto-import-config.worker";
import { readDatabasesConfigHandler, writeDatabasesConfigHandler } from "node-api/src/lib/databases-config.worker";

//
// The task that records a newly created default database, so nothing creates it a second time.
//
// It writes the database's path into auto-import.toml and adds the database to databases.toml, which
// is what makes it appear in the app's database list. Both files live in the app's storage sandbox
// and neither is reachable from the WebView or from native code, so this runs in the worker, beside
// the pass that has just created the database.
//
// This is one task rather than two because the two writes have to happen together: a database
// recorded as the default but missing from the list is one the user cannot open, and a database in
// the list that is not recorded as the default is created again on the next pass.
//

//
// Input for the record-default-database task.
//
export interface IRecordDefaultDatabaseData {
    // The sandbox-relative path of the database that has just been created.
    databasePath: string;
}

//
// Handler for the record-default-database task.
//
export async function recordDefaultDatabaseHandler(data: IRecordDefaultDatabaseData, context: ITaskContext): Promise<void> {
    if (!data.databasePath) {
        throw new Error("databasePath is required");
    }

    const autoImportFile = await readAutoImportConfigFile(AUTO_IMPORT_CONFIG_PATH);
    await writeAutoImportConfigHandler({
        configPath: AUTO_IMPORT_CONFIG_PATH,
        settings: autoImportFile.settings,
        defaultDatabasePath: data.databasePath,
        pauseBetweenRunsMs: autoImportFile.pauseBetweenRunsMs,
    }, context);

    const databasesConfig = await readDatabasesConfigHandler({ configPath: DATABASES_CONFIG_PATH }, context);
    const alreadyListed = databasesConfig.databases.some(entry => entry.path === data.databasePath);
    if (alreadyListed) {
        return;
    }

    await writeDatabasesConfigHandler({
        configPath: DATABASES_CONFIG_PATH,
        databases: [
            ...databasesConfig.databases,
            {
                name: DEFAULT_DATABASE_DISPLAY_NAME,
                description: "",
                path: data.databasePath,
            },
        ],
        recentDatabaseNames: databasesConfig.recentDatabaseNames,
    }, context);
}
