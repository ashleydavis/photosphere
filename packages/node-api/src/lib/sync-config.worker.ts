//
// Reads and writes sync.toml as a background task.
//
// The same arrangement as auto-import-config.worker.ts and for the same reason: the mobile WebView
// holds these settings but cannot open a file, so its reads and writes run in the embedded worker
// over the storage layer. Putting them in a file rather than in the WebView's config store is what
// lets a background sync that runs while the app is off screen find out whether it is switched on at
// all, and whether it may use a cellular connection.
//
// The file contents come from sync-config-format.ts, the same module every reader converts through,
// so a file written here is readable by anything else that opens it by construction.
//

import { parse as parseToml, stringify as stringifyToml } from "smol-toml";
import type { ITaskContext } from "task-queue";
import { log } from "utils";
import { FileStorage } from "storage";
import { resolveSyncPauseMs, type ISyncFile, type ISyncSettings } from "api/src/lib/sync-settings";
import { syncFileToToml, tomlToSyncFile, type ITomlSyncConfig } from "./sync-config-format";

//
// Input for the read-sync-config task.
//
export interface IReadSyncConfigData {
    // Sandbox-relative path of sync.toml.
    configPath: string;
}

//
// Input for the write-sync-config task.
//
export interface IWriteSyncConfigData {
    // Sandbox-relative path of sync.toml.
    configPath: string;

    // The settings to write.
    settings: ISyncSettings;

    // The database the background sync pushes, or undefined when none has been opened yet.
    databasePath?: string;

    // The gap between background sync passes, in milliseconds.
    pauseBetweenRunsMs: number;
}

//
// Result of the read-sync-config task.
//
export interface IReadSyncConfigResult {
    // The settings, filled from the defaults when the file does not exist or cannot be read.
    settings: ISyncSettings;

    // The database the background sync pushes, absent when none has been opened yet.
    databasePath?: string;

    // The gap between background sync passes, in milliseconds.
    pauseBetweenRunsMs: number;

    // Whether the file was there at all.
    //
    // The interface needs to tell "nobody has written this yet" from "somebody switched syncing
    // off", because those two want opposite things: the first is a fresh install that should be
    // seeded with syncing on, and the second is a user's decision that must be left alone. The
    // settings alone cannot say which it is, since both read as switched off.
    exists: boolean;
}

//
// Reads and converts the file at the given path, returning the defaults when it is not there.
//
// A file that will not parse also reads as the defaults rather than throwing, which for these
// settings means syncing switched off. This one is written by the app and never shown to the user,
// so a corrupt copy is a bug somewhere else, and throwing here would take the settings card that
// could fix it down with it. The parse failure is logged so it is not silent.
//
export async function readSyncConfigFile(configPath: string): Promise<ISyncFile> {
    const storage = new FileStorage("fs:");
    if (!await storage.fileExists(configPath)) {
        return tomlToSyncFile(undefined);
    }

    const contents = await storage.read(configPath);
    if (!contents) {
        return tomlToSyncFile(undefined);
    }

    let toml: ITomlSyncConfig;
    try {
        toml = parseToml(contents.toString("utf8")) as ITomlSyncConfig;
    }
    catch (error) {
        log.error(`The syncing settings at "${configPath}" could not be parsed, using the defaults: ${error}`);
        return tomlToSyncFile(undefined);
    }

    return tomlToSyncFile(toml);
}

//
// Handler for the read-sync-config task.
//
export async function readSyncConfigHandler(data: IReadSyncConfigData, _context: ITaskContext): Promise<IReadSyncConfigResult> {
    if (!data.configPath) {
        throw new Error("configPath is required");
    }

    const storage = new FileStorage("fs:");
    const exists = await storage.fileExists(data.configPath);
    const contents = await readSyncConfigFile(data.configPath);

    const result: IReadSyncConfigResult = {
        settings: contents.settings,
        pauseBetweenRunsMs: contents.pauseBetweenRunsMs,
        exists,
    };
    if (contents.databasePath !== undefined) {
        result.databasePath = contents.databasePath;
    }
    return result;
}

//
// Handler for the write-sync-config task.
//
export async function writeSyncConfigHandler(data: IWriteSyncConfigData, _context: ITaskContext): Promise<void> {
    if (!data.configPath) {
        throw new Error("configPath is required");
    }
    if (!data.settings) {
        throw new Error("settings is required");
    }

    const contents = buildSyncConfigToml({
        settings: data.settings,
        databasePath: data.databasePath,
        pauseBetweenRunsMs: resolveSyncPauseMs(data.pauseBetweenRunsMs),
    });
    const storage = new FileStorage("fs:");
    await storage.write(data.configPath, "application/toml", Buffer.from(contents, "utf8"));
}

//
// Renders the whole file as the TOML text of a sync.toml, returning it rather than writing it
// anywhere.
//
// Factored out of the write handler so a host-side script can produce a file the read handler reads
// back exactly, which is how a mobile smoke test establishes the syncing settings from outside the
// app.
//
export function buildSyncConfigToml(contents: ISyncFile): string {
    return stringifyToml(syncFileToToml(contents)) + "\n";
}
