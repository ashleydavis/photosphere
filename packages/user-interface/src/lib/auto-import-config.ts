// Imported from the module rather than the package barrel: the barrel reaches Node-only code
// (serialization pulls in zlib), and this file is bundled for the browser as well.
import {
    DEFAULT_AUTO_IMPORT_SETTINGS,
    IAutoImportSettings,
    IAutoImportSource,
    IRawAutoImportSettings,
    normaliseAutoImportSettings,
} from "api/src/lib/auto-import-settings";
import { IConfig } from "../context/config-context";

//
// Reading and writing the automatic import settings through the generic config store.
//
// These are plain functions over IConfig rather than a hook, so the decisions they make (what the
// defaults are, which database is the default one, what happens when a second one is made default)
// can be unit tested. The React parts that call them stay thin.
//

//
// Config key holding whether automatic import is switched on.
//
export const AUTO_IMPORT_ENABLED_KEY = "autoImportEnabled";

//
// Config key holding the path of the database automatic import writes to.
//
export const DEFAULT_DATABASE_PATH_KEY = "defaultDatabasePath";

//
// Config key holding the list of places that are watched.
//
export const AUTO_IMPORT_SOURCES_KEY = "autoImportSources";

//
// Reads the automatic import settings, filling anything missing or malformed from the defaults.
//
export async function loadAutoImportSettings(config: IConfig): Promise<IAutoImportSettings> {
    const raw: IRawAutoImportSettings = {
        enabled: await config.get<boolean>(AUTO_IMPORT_ENABLED_KEY),
        sources: await config.get<IAutoImportSource[]>(AUTO_IMPORT_SOURCES_KEY),
    };
    return normaliseAutoImportSettings(raw);
}

//
// Writes the automatic import settings.
//
// Only the two the user can change are stored. The pacing and the poll interval are not settings
// the interface offers, so they stay at their defaults rather than being written out and then read
// back as if the user had chosen them.
//
export async function saveAutoImportSettings(config: IConfig, settings: IAutoImportSettings): Promise<void> {
    await config.set(AUTO_IMPORT_ENABLED_KEY, settings.enabled);
    await config.set(AUTO_IMPORT_SOURCES_KEY, settings.sources);
}

//
// The path of the database automatic import writes to, or undefined when there is not one yet.
//
export async function getDefaultDatabasePath(config: IConfig): Promise<string | undefined> {
    const path = await config.get<string>(DEFAULT_DATABASE_PATH_KEY);
    if (typeof path !== "string" || path.length === 0) {
        return undefined;
    }
    return path;
}

//
// Records which database automatic import writes to.
//
export async function setDefaultDatabasePath(config: IConfig, databasePath: string): Promise<void> {
    await config.set(DEFAULT_DATABASE_PATH_KEY, databasePath);
}

//
// The settings a brand new installation starts from, with the given places to watch.
//
export function buildInitialAutoImportSettings(sources: IAutoImportSource[]): IAutoImportSettings {
    return {
        ...DEFAULT_AUTO_IMPORT_SETTINGS,
        enabled: true,
        sources,
    };
}

//
// An entry in the databases list, as far as marking a default is concerned.
//
export interface IDefaultableDatabase {
    // The database's path, which is what the default is recorded as.
    path: string;

    // Whether this entry is the one automatic import writes to.
    isDefault?: boolean;
}

//
// Returns the entries with exactly one of them marked as the default.
//
// Exactly one is the whole rule: making a second database the default has to clear the first, or
// the app has two places it believes photos are being backed up to and only one of them is really
// receiving them.
//
export function markDefaultDatabase<EntryType extends IDefaultableDatabase>(entries: EntryType[], defaultPath: string | undefined): EntryType[] {
    return entries.map(entry => ({
        ...entry,
        isDefault: defaultPath !== undefined && entry.path === defaultPath,
    }));
}

//
// The path of whichever entry is marked as the default, or undefined when none is.
//
export function findDefaultDatabasePath(entries: IDefaultableDatabase[]): string | undefined {
    const defaultEntry = entries.find(entry => entry.isDefault === true);
    return defaultEntry ? defaultEntry.path : undefined;
}
