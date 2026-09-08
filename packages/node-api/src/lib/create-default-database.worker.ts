import type { ITaskContext } from "task-queue";
import { DEFAULT_DATABASE_DISPLAY_NAME } from "api/src/lib/auto-import-mobile";
import { checkDatabaseExists } from "./media-file-database";
import { createDatabaseHandler } from "./create-database.worker";
import { readConfigFromStorage, writeConfigHandler } from "./config.worker";
import { readDatabasesConfigHandler, writeDatabasesConfigHandler } from "./databases-config.worker";

//
// The task that creates the default private photo database and records it.
//
// This is what switching automatic import on does before it imports anything: the user has asked for
// somewhere to put their photos and has not chosen it, so the app makes it. It creates the database,
// writes its path into the automatic import section of config.yaml, and adds it to databases.toml,
// which is what makes it appear in the app's database list.
//
// All three in one task because they have to happen together: a database recorded as the default but
// missing from the list is one the user cannot open, and a database that exists but is recorded
// nowhere is created again on the next pass, on top of the one that is already there.
//
// Every platform runs this same task, so the default database comes to exist one way rather than one
// way per platform. On a phone the background import's pass queues it, and neither file it writes is
// reachable from the WebView or from native code; on the desktop the main process queues it on the
// worker pool.
//
// The two files are named by the caller, because they sit in different places: at the root of the
// app's storage sandbox on a phone, in the config directory on the desktop.
//
// create-database is left alone and still creates a database on its own: that is the one the user
// makes themselves, which is not the default and is recorded by the interface that asked for it.
//

//
// Input for the create-default-database task.
//
export interface ICreateDefaultDatabaseData {
    // The path to create the database at.
    databasePath: string;

    // The path of config.yaml, which is told which database automatic import writes to.
    configPath: string;

    // The path of databases.toml, which the database is added to so it appears in the list.
    databasesConfigPath: string;

    // Whether the app should open this database once it exists.
    //
    // Whoever asks for the database says here whether it is also being asked for on screen, so a
    // database made because the user switched automatic import on is the one the user ends up
    // looking at. The task says so by sending the message below; opening it is the interface's.
    open: boolean;
}

//
// The message the task sends when it has made a database that was asked for on screen.
//
// A task message rather than anything platform-specific, because a task message is the one way a
// task reaches the interface that works the same everywhere: the Electron main process forwards it
// to the renderer, and the native plugin emits it to the WebView. So the interface has one thing to
// listen to and neither platform needs an opener of its own.
//
export interface IDatabaseOpenedMessage {
    // Names this message among all the messages tasks send.
    type: "database-opened";

    // The database to open.
    databasePath: string;
}

//
// Handler for the create-default-database task.
//
export async function createDefaultDatabaseHandler(data: ICreateDefaultDatabaseData, context: ITaskContext): Promise<void> {
    if (!data.databasePath) {
        throw new Error("databasePath is required");
    }
    if (!data.configPath) {
        throw new Error("configPath is required");
    }
    if (!data.databasesConfigPath) {
        throw new Error("databasesConfigPath is required");
    }

    // Only made when it is not there. A pass that was killed between making the database and
    // recording it leaves one behind, and create-database refuses a directory that already holds a
    // database, so without this the next pass would fail on it and every pass after that.
    if (!await checkDatabaseExists(data.databasePath)) {
        await createDatabaseHandler({ databasePath: data.databasePath }, context);
    }

    const { config } = await readConfigFromStorage(data.configPath);
    const autoImportFile = config.autoImport;
    // Only the automatic import section is sent, so the syncing settings in the same file are left
    // exactly as they were.
    await writeConfigHandler({
        configPath: data.configPath,
        autoImport: {
            settings: autoImportFile.settings,
            defaultDatabasePath: data.databasePath,
            pauseBetweenRunsMs: autoImportFile.pauseBetweenRunsMs,
        },
    }, context);

    const databasesConfig = await readDatabasesConfigHandler({ configPath: data.databasesConfigPath }, context);
    const alreadyListed = databasesConfig.databases.some(entry => entry.path === data.databasePath);
    if (!alreadyListed) {
        await writeDatabasesConfigHandler({
            configPath: data.databasesConfigPath,
            databases: [
                ...databasesConfig.databases,
                {
                    name: DEFAULT_DATABASE_DISPLAY_NAME,
                    description: "",
                    path: data.databasePath,
                },
            ],
            recentDatabaseNames: databasesConfig.recentDatabaseNames,

            // Carried through rather than dropped: this rewrites the whole file to add one entry, and
            // writing undefined here would close the database the user had open.
            lastDatabase: databasesConfig.lastDatabase,
        }, context);
    }

    // Said last, so the interface is told to open a database that is made, recorded and listed.
    if (data.open) {
        const openedMessage: IDatabaseOpenedMessage = {
            type: "database-opened",
            databasePath: data.databasePath,
        };
        context.sendMessage(openedMessage);
    }
}
