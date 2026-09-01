import {
    INITIAL_SYNC_SETTINGS,
    normaliseSyncSettings,
    resolveSyncPauseMs,
    type ISyncFile,
    type ISyncSettings,
} from "api/src/lib/sync-settings";
import { SYNC_ENABLED_CONFIG_KEY, SYNC_ONLY_ON_WIFI_CONFIG_KEY } from "user-interface/src/lib/sync-config";

//
// Client-side reading and writing of the mobile syncing settings.
//
// These live in sync.toml in the app's storage sandbox, beside databases.toml and auto-import.toml.
// They used to live in the WebView's config store, which nothing outside the WebView can read: the
// background sync loop, which runs while the app is off screen, had no way to find out whether
// syncing was switched on or whether it was restricted to Wi-Fi.
//
// The WebView cannot open a file, so the read and the write are handed to an ISyncConfigFile, which
// the platform provider implements with the embedded worker's read-sync-config / write-sync-config
// tasks. Keeping that behind an interface is what makes this module unit-testable without a device,
// the same arrangement mobile-auto-import-file.ts uses for auto-import.toml.
//
// The settings card knows nothing about any of this: it reads and writes the same two config keys on
// every platform, and on mobile the platform provider routes those keys here instead of to local
// storage.
//

//
// What sync.toml holds, and whether it was there at all.
//
export interface ISyncFileContents {
    // The settings, already filled from the defaults by the reader.
    settings: ISyncSettings;

    // The gap between background sync passes, in milliseconds.
    pauseBetweenRunsMs: number;

    // Whether the file exists. False means nobody has written it yet, which is a different thing
    // from syncing having been switched off, even though both read as switched off.
    exists: boolean;
}

//
// Reads and writes sync.toml. Implemented by the platform provider over the embedded worker, and by
// an in-memory double in tests.
//
export interface ISyncConfigFile {
    // Reads the file, reporting whether it was there.
    read(): Promise<ISyncFileContents>;

    // Writes the file, replacing its contents.
    write(contents: ISyncFile): Promise<void>;
}

//
// The config keys syncing keeps in the file rather than in local storage.
//
export const SYNC_FILE_KEYS: string[] = [
    SYNC_ENABLED_CONFIG_KEY,
    SYNC_ONLY_ON_WIFI_CONFIG_KEY,
];

//
// True when a config key belongs to the syncing settings file.
//
export function isSyncFileKey(key: string): boolean {
    return SYNC_FILE_KEYS.includes(key);
}

//
// Tail of the chain that serialises the read-modify-write operations against the file.
//
// Every write below reads the whole file, changes one field and writes the whole file back, and the
// read and the write are separate async round-trips to the embedded worker. Without serialisation
// two writes issued back to back interleave: both read the same starting contents, and the second
// write clobbers the field the first one changed. The same reasoning, and the same fix, as the
// chain in mobile-auto-import-file.ts.
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
// Writes the settings a fresh installation starts from, unless the file is already there.
//
// The file has to exist for the background loop to sync anything, because a file it cannot read
// reads as syncing switched off. That default is right for the loop and wrong for a new user, whose
// two toggles show syncing on and Wi-Fi-only on before they touch anything, so the app writes what
// the toggles say the first time it runs and the loop and the interface agree from then on.
//
// An existing file is left exactly as it is. Overwriting it would put syncing back on for somebody
// who had switched it off, every time the app started.
//
export async function seedSyncSettingsFile(configFile: ISyncConfigFile): Promise<void> {
    return withFileLock(async () => {
        const existing = await configFile.read();
        if (existing.exists) {
            return;
        }

        await configFile.write({
            settings: { ...INITIAL_SYNC_SETTINGS },
            pauseBetweenRunsMs: resolveSyncPauseMs(existing.pauseBetweenRunsMs),
        });
    });
}

//
// Returns the stored value of one syncing config key, or undefined when the file is not there yet.
//
// Undefined rather than the reader's defaults, because the settings card treats undefined as "no
// value stored" and falls back to what its toggles show. A file nobody has written yet reads as
// syncing off, which is the right answer for the background loop and the wrong one to put in front
// of a new user.
//
export async function getSyncFileValue(configFile: ISyncConfigFile, key: string): Promise<boolean | undefined> {
    if (!isSyncFileKey(key)) {
        throw new Error(`"${key}" is not a syncing config key.`);
    }

    const contents = await configFile.read();
    if (!contents.exists) {
        return undefined;
    }

    if (key === SYNC_ENABLED_CONFIG_KEY) {
        return contents.settings.enabled;
    }

    return contents.settings.onlyOnWifi;
}

//
// Stores the value of one syncing config key, leaving the rest of the file as it was.
//
// The whole read-merge-write happens with no other write in flight, because switching one toggle
// while another write is on its way would otherwise lose one of the two.
//
export async function setSyncFileValue(configFile: ISyncConfigFile, key: string, value: boolean | undefined): Promise<void> {
    if (!isSyncFileKey(key)) {
        throw new Error(`"${key}" is not a syncing config key.`);
    }

    return withFileLock(async () => {
        const existing = await configFile.read();
        const settings: ISyncSettings = existing.exists
            ? normaliseSyncSettings(existing.settings)
            : { ...INITIAL_SYNC_SETTINGS };

        if (key === SYNC_ENABLED_CONFIG_KEY) {
            settings.enabled = value === true;
        }
        else {
            settings.onlyOnWifi = value === true;
        }

        await configFile.write({
            settings,
            pauseBetweenRunsMs: resolveSyncPauseMs(existing.pauseBetweenRunsMs),
        });
    });
}
