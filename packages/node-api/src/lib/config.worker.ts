//
// Reads and writes config.yaml as a background task.
//
// The same arrangement as databases-config.worker.ts and for the same reason: the mobile WebView
// holds these settings but cannot open a file, so its reads and writes run in the embedded worker
// over the storage layer. Putting them in a file rather than in the WebView's own store is what lets
// the background import and the background sync, which run while the app is off screen, find out
// whether they are switched on at all.
//
// One file holds every feature's settings, so a write merges rather than replaces: switching syncing
// on must not wipe what automatic import is watching. Every section the caller does not send is left
// exactly as it was on disk.
//
// The file contents come from config-format.ts, the same module every reader converts through, so a
// file written here is readable by anything else that opens it by construction.
//

import yaml from "js-yaml";
import type { ITaskContext } from "task-queue";
import { log } from "utils";
import { FileStorage } from "storage";
import type { IAutoImportSettings } from "api/src/lib/auto-import-settings";
import { resolveAutoImportPauseMs, type IAutoImportFile } from "api/src/lib/auto-import-mobile";
import { resolveSyncPauseMs, type ISyncFile, type ISyncSettings } from "api/src/lib/sync-settings";
import {
    buildConfigYaml,
    configFileToYaml,
    defaultConfigFile,
    parseConfigYamlChecked,
    sectionsPresent,
    type IConfigSectionsPresent,
    type IConfigFile,
    type IYamlConfigFile,
} from "./config-format";
import {
    appConfigSettings,
    appConfigToYaml,
    setAppConfigValue,
    yamlToAppConfig,
    type IAppConfigValue,
} from "./app-config-format";

//
// Input for the read-config task.
//
export interface IReadConfigData {
    // Sandbox-relative path of config.yaml.
    configPath: string;
}

//
// The automatic import part of a write, sent only when the caller is changing it.
//
export interface IWriteConfigAutoImport {
    // The settings to write.
    settings: IAutoImportSettings;

    // The database automatic import writes to, or undefined when none has been chosen yet.
    defaultDatabasePath?: string;

    // The gap between background import passes, in milliseconds.
    pauseBetweenRunsMs: number;
}

//
// The syncing part of a write, sent only when the caller is changing it.
//
export interface IWriteConfigSync {
    // The settings to write.
    settings: ISyncSettings;

    // The database the background sync pushes, or undefined when none has been opened yet.
    databasePath?: string;

    // The gap between background sync passes, in milliseconds.
    pauseBetweenRunsMs: number;
}

//
// One flat key the caller is changing.
//
// A missing `value` clears the key, which is what IConfig.clear means, and is not the same as the
// entry not being sent at all. The two have to be told apart because the entry crosses the bridge to
// the phone as JSON, where an undefined property simply disappears: a caller that meant "clear this"
// would arrive looking like a caller that meant nothing, so the key would be left as it was.
//
export interface IWriteConfigEntry {
    // The flat key the interface uses.
    key: string;

    // What to store under it. Absent clears the key.
    value?: IAppConfigValue;
}

//
// Input for the write-config task.
//
// Every part is optional, and a part that is absent is left as it is on disk. That is what keeps two
// features that are switched on separately from overwriting each other now they share a file: the
// settings card writes the one section the user touched.
//
export interface IWriteConfigData {
    // Sandbox-relative path of config.yaml.
    configPath: string;

    // The automatic import settings, when they are what is being changed.
    autoImport?: IWriteConfigAutoImport;

    // The syncing settings, when they are what is being changed.
    sync?: IWriteConfigSync;

    // The flat keys being changed, each written where this file keeps it.
    entries?: IWriteConfigEntry[];
}

//
// Result of the read-config task.
//
export interface IReadConfigResult {
    // The automatic import settings, the database they write to, and the pacing of the loop.
    autoImport: IAutoImportFile;

    // The syncing settings, the database the loop pushes, and its pacing.
    sync: ISyncFile;

    // Whether the syncing settings have ever been written.
    //
    // The interface needs to tell "nobody has written this yet" from "somebody switched syncing
    // off", because those two want opposite things: the first is a fresh install that should be
    // seeded with syncing on, and the second is a user's decision that must be left alone. The
    // settings alone cannot say which it is, since both read as switched off.
    //
    // It reports the `sync` section rather than the file, which matters now that one file holds
    // everything: automatic import writing its own section brings the file into being, and answering
    // "yes, the file is there" would tell a fresh install its syncing settings had been chosen. The
    // seeding step would then skip, leaving syncing switched off on a phone whose toggles say it is
    // on.
    syncSettingsWritten: boolean;

    // Whether the automatic import settings have ever been written, for the same reason.
    autoImportSettingsWritten: boolean;

    // Every setting that has a value, under the flat name the interface uses for it. Flat rather than
    // the sectioned document so the phone's WebView can answer a get by indexing it, without needing
    // the module that knows which section each key belongs in.
    settings: Record<string, IAppConfigValue>;
}

//
// What reading the file gives back: the settings, and which sections were actually in it.
//
export interface IConfigRead {
    // The settings, filled from the defaults for anything the file did not say.
    config: IConfigFile;

    // Which sections the file actually carried. A caller needs this to tell a section nobody has
    // written from one that has been switched off, because both read as switched off.
    present: IConfigSectionsPresent;

    // The document as it was on disk, which is what the flat key/value view is built from. Undefined
    // when there is no file, or when it would not parse.
    document?: IYamlConfigFile;
}

//
// Reads the config file through storage, which is how it is reached on a device.
//
// A file that is not there, and one that will not parse, both come back as the defaults rather than
// throwing, which for these settings means both loops switched off. This file is written by the app
// and never shown to the user, so a corrupt copy is a bug somewhere else, and throwing here would
// take the settings card that could fix it down with it. The parse failure is logged so it is not
// silent.
//
export async function readConfigFromStorage(configPath: string): Promise<IConfigRead> {
    const storage = new FileStorage("fs:");
    const absent: IConfigRead = {
        config: defaultConfigFile(),
        present: sectionsPresent(undefined),
    };

    if (!await storage.fileExists(configPath)) {
        return absent;
    }

    const contents = await storage.read(configPath);
    if (!contents) {
        return absent;
    }

    const parsed = parseConfigYamlChecked(contents.toString("utf8"));
    if (parsed.malformed) {
        log.error(`The settings at "${configPath}" could not be parsed, using the defaults: ${parsed.parseError}`);
    }
    return {
        config: parsed.config,
        present: parsed.present,
        document: parsed.document,
    };
}

//
// Handler for the read-config task.
//
export async function readConfigHandler(data: IReadConfigData, _context: ITaskContext): Promise<IReadConfigResult> {
    if (!data.configPath) {
        throw new Error("configPath is required");
    }

    const contents = await readConfigFromStorage(data.configPath);

    return {
        autoImport: contents.config.autoImport,
        sync: contents.config.sync,
        syncSettingsWritten: contents.present.sync,
        autoImportSettingsWritten: contents.present.autoImport,
        settings: appConfigSettings(yamlToAppConfig(contents.document)),
    };
}

//
// Handler for the write-config task.
//
// A read-modify-write: it reads what is on disk, replaces only the sections the caller sent, and
// writes the whole document back. Reading first is what keeps the sections nobody touched, including
// the ones this task has no notion of at all.
//
export async function writeConfigHandler(data: IWriteConfigData, _context: ITaskContext): Promise<void> {
    if (!data.configPath) {
        throw new Error("configPath is required");
    }
    if (!data.autoImport && !data.sync && !data.entries) {
        throw new Error("write-config was given no autoImport section, no sync section and no settings to write, so there is nothing to write.");
    }

    const storage = new FileStorage("fs:");
    const contents = await readConfigFromStorage(data.configPath);
    const current = contents.config;
    const present = contents.present;

    if (data.autoImport) {
        if (!data.autoImport.settings) {
            throw new Error("autoImport.settings is required");
        }
        current.autoImport = {
            settings: data.autoImport.settings,
            defaultDatabasePath: data.autoImport.defaultDatabasePath,
            pauseBetweenRunsMs: resolveAutoImportPauseMs(data.autoImport.pauseBetweenRunsMs),
        };
    }

    if (data.sync) {
        if (!data.sync.settings) {
            throw new Error("sync.settings is required");
        }
        current.sync = {
            settings: data.sync.settings,
            databasePath: data.sync.databasePath,
            pauseBetweenRunsMs: resolveSyncPauseMs(data.sync.pauseBetweenRunsMs),
        };
    }

    // A feature's section goes into the file once it has been set, and stays once it is there. Both
    // halves matter: writing a section nobody has chosen would tell a fresh install its settings had
    // already been decided, and dropping one that had been chosen would lose the user's decision.
    let document = configFileToYaml(current, {
        autoImport: present.autoImport || data.autoImport !== undefined,
        sync: present.sync || data.sync !== undefined,
    });

    // The settings the interface names go on last, through the flat view, which is the only thing
    // that knows which section each of them belongs in. It merges into the document rather than
    // rebuilding it, so it changes the keys it was given and leaves the rest of the file alone.
    if (data.entries) {
        const appConfig = yamlToAppConfig(document);
        for (const entry of data.entries) {
            if (!entry.key) {
                throw new Error("write-config was given a setting with no key.");
            }
            setAppConfigValue(appConfig, entry.key, entry.value);
        }
        document = appConfigToYaml(appConfig, document);
    }

    const text = yaml.dump(document);
    await storage.write(data.configPath, "application/yaml", Buffer.from(text, "utf8"));
}

//
// Renders the whole file as the text of a config.yaml, returning it rather than writing it anywhere.
//
// Re-exported from the format module so a host-side script can produce a file the read handler reads
// back exactly, which is how a mobile smoke test establishes settings from outside the app.
//
export { buildConfigYaml };
