import { normaliseAutoImportSettings, type IAutoImportSettings, type IAutoImportSource } from "api/src/lib/auto-import-settings";
import { resolveAutoImportPauseMs, type IAutoImportFile } from "api/src/lib/auto-import-mobile";
import { AUTO_IMPORT_ENABLED_KEY, AUTO_IMPORT_SOURCES_KEY, DEFAULT_DATABASE_PATH_KEY } from "user-interface/src/lib/auto-import-config";

//
// Client-side reading and writing of the mobile automatic import settings.
//
// These live in auto-import.toml in the app's storage sandbox, beside databases.toml. They used to
// live in the WebView's localStorage, which nothing outside the WebView can read: a background
// import running while the app is off screen had no way to find out whether it was switched on, what
// it should be watching, or which database to write to.
//
// The WebView cannot open a file, so the read and the write are handed to an IAutoImportConfigFile,
// which the platform provider implements with the embedded worker's read-auto-import-config /
// write-auto-import-config tasks. Keeping that behind an interface is what makes this module
// unit-testable without a device, the same arrangement mobile-config-store.ts uses for
// databases.toml.
//
// The settings card knows nothing about any of this: it reads and writes the same three config keys
// on every platform, and on mobile the platform provider routes those keys here instead of to local
// storage.
//

//
// Reads and writes auto-import.toml. Implemented by the platform provider over the embedded worker,
// and by an in-memory double in tests.
//
export interface IAutoImportConfigFile {
    // Reads the file, returning the defaults when it does not exist.
    read(): Promise<IAutoImportFile>;

    // Writes the file, replacing its contents.
    write(contents: IAutoImportFile): Promise<void>;
}

//
// The config keys automatic import keeps in the file rather than in local storage.
//
export const AUTO_IMPORT_FILE_KEYS: string[] = [
    AUTO_IMPORT_ENABLED_KEY,
    AUTO_IMPORT_SOURCES_KEY,
    DEFAULT_DATABASE_PATH_KEY,
];

//
// True when a config key belongs to the automatic import file.
//
export function isAutoImportFileKey(key: string): boolean {
    return AUTO_IMPORT_FILE_KEYS.includes(key);
}

//
// Tail of the chain that serialises the read-modify-write operations against the file.
//
// Every write below reads the whole file, changes one field and writes the whole file back, and the
// read and the write are separate async round-trips to the embedded worker. Without serialisation
// two writes issued back to back interleave: both read the same starting contents, and the second
// write clobbers the field the first one changed. The settings card writes the toggle and the
// watched places as two separate calls, so this is not a rare case. The same reasoning, and the same
// fix, as the config chain in mobile-config-store.ts.
//
let fileOperationChain: Promise<void> = Promise.resolve();

//
// Runs one read-modify-write against the file with no other such operation in flight.
//
// The chain continues on both settle paths so one failed operation does not wedge every later one.
// The caller still sees its own rejection: only the chain's copy of the outcome is discarded.
//
async function withFileLock<OperationResult>(operation: () => Promise<OperationResult>): Promise<OperationResult> {
    const runAfterPrevious = fileOperationChain.then(operation, operation);
    fileOperationChain = runAfterPrevious.then(() => undefined, () => undefined);
    return runAfterPrevious;
}

//
// Reads the automatic import settings, the default database path and the background pacing.
//
// A file that is not there, and a file that will not parse, both read as the defaults. This one is
// written by the app and never shown to the user, so a copy that cannot be read is a bug elsewhere,
// and throwing here would stop the app starting over a settings file.
//
export async function readAutoImportFile(configFile: IAutoImportConfigFile): Promise<IAutoImportFile> {
    const contents = await configFile.read();
    return {
        settings: normaliseAutoImportSettings(contents.settings),
        defaultDatabasePath: contents.defaultDatabasePath,
        pauseBetweenRunsMs: resolveAutoImportPauseMs(contents.pauseBetweenRunsMs),
    };
}

//
// Replaces the whole file with the given contents.
//
export async function writeAutoImportFile(configFile: IAutoImportConfigFile, contents: IAutoImportFile): Promise<void> {
    return withFileLock(async () => {
        await configFile.write({
            settings: normaliseAutoImportSettings(contents.settings),
            defaultDatabasePath: contents.defaultDatabasePath,
            pauseBetweenRunsMs: resolveAutoImportPauseMs(contents.pauseBetweenRunsMs),
        });
    });
}

//
// Returns the stored value of one automatic import config key, or undefined when it has none.
//
export async function getAutoImportFileValue(configFile: IAutoImportConfigFile, key: string): Promise<boolean | string | IAutoImportSource[] | undefined> {
    const contents = await readAutoImportFile(configFile);

    if (key === AUTO_IMPORT_ENABLED_KEY) {
        return contents.settings.enabled;
    }

    if (key === AUTO_IMPORT_SOURCES_KEY) {
        return contents.settings.sources;
    }

    if (key === DEFAULT_DATABASE_PATH_KEY) {
        return contents.defaultDatabasePath;
    }

    throw new Error(`"${key}" is not an automatic import config key.`);
}

//
// Stores the value of one automatic import config key, leaving the rest of the file as it was.
//
// The whole read-merge-write happens with no other write in flight, because the settings card
// changes one key at a time and the two writes it makes for one change would otherwise each
// overwrite the other's field.
//
export async function setAutoImportFileValue(configFile: IAutoImportConfigFile, key: string, value: boolean | string | IAutoImportSource[] | undefined): Promise<void> {
    if (!isAutoImportFileKey(key)) {
        throw new Error(`"${key}" is not an automatic import config key.`);
    }

    return withFileLock(async () => {
        const existing = await configFile.read();
        const settings: IAutoImportSettings = normaliseAutoImportSettings(existing.settings);
        let defaultDatabasePath = existing.defaultDatabasePath;

        if (key === AUTO_IMPORT_ENABLED_KEY) {
            settings.enabled = value === true;
        }
        else if (key === AUTO_IMPORT_SOURCES_KEY) {
            settings.sources = normaliseAutoImportSettings({ sources: value as IAutoImportSource[] }).sources;
        }
        else {
            defaultDatabasePath = typeof value === "string" && value.length > 0 ? value : undefined;
        }

        await configFile.write({
            settings,
            defaultDatabasePath,
            pauseBetweenRunsMs: resolveAutoImportPauseMs(existing.pauseBetweenRunsMs),
        });
    });
}
