import {
    ALL_DEVICE_MEDIA_ALBUM_ID,
    IAutoImportSettings,
    IAutoImportSource,
    normaliseAutoImportSettings,
} from "./auto-import-settings";

//
// What the mobile app should do about automatic import, worked out from its settings alone.
//
// This mirrors the desktop planner (packages/node-api/src/lib/auto-import-desktop.ts): the decisions
// live here as plain functions so they can be unit tested, and the caller is left with the parts
// that need the app (creating the database, starting the task, asking for the permission).
//
// It lives in this package rather than in the mobile frontend because the native background import
// asks for the same plan, through a worker task, and the worker cannot reach the frontend's React
// code. One planner answers both, so a phone driving the import from its own service and a phone
// driving it from the WebView cannot decide different things.
//

//
// Everything the mobile automatic import settings file holds.
//
// The settings themselves, the database they are imported into, and the pacing of the background
// loop. It is here rather than beside the file's TOML conversion because the WebView holds these
// values and cannot reach the code that opens the file, so the type has to sit in a package with no
// platform of its own.
//
export interface IAutoImportFile {
    // The settings automatic import runs with.
    settings: IAutoImportSettings;

    // The sandbox-relative path of the database automatic import writes to, or undefined when no
    // default database has been chosen yet.
    defaultDatabasePath: string | undefined;

    // The gap between background import passes, in milliseconds. Already resolved, so a file asking
    // for zero or a negative gap comes back holding the default.
    pauseBetweenRunsMs: number;
}

//
// How long the background import waits between passes when the settings file does not say.
//
// A pass reads its sources to the end and stops, so this is the gap before the next one starts. Long
// enough that a phone is not scanning its library continuously, short enough that a photo taken now
// is backed up in the next minute or so.
//
export const DEFAULT_AUTO_IMPORT_PAUSE_MS = 30000;

//
// The gap between background import passes, in milliseconds.
//
// Zero, a negative number, and anything that is not a finite number all fall back to the default.
// The value is read from a file the user may edit, and a gap of zero is a loop that starts a fresh
// pass the instant the last one ends, which on a phone is a flat battery rather than a fast backup.
//
export function resolveAutoImportPauseMs(pauseMs: number | undefined): number {
    if (typeof pauseMs !== "number" || !Number.isFinite(pauseMs) || pauseMs <= 0) {
        return DEFAULT_AUTO_IMPORT_PAUSE_MS;
    }
    return pauseMs;
}

//
// The folder the default private database is created in, inside the app sandbox.
//
// The same fixed name the desktop app uses, so a user with both sees the same database name and a
// support answer about one applies to the other.
//
export const DEFAULT_DATABASE_FOLDER_NAME = "photosphere-default";

//
// The name the default private database is listed under.
//
export const DEFAULT_DATABASE_DISPLAY_NAME = "My Photos";

//
// The source tag every automatic import task is queued under, so it can be cancelled as a group when
// the setting is switched off.
//
export const AUTO_IMPORT_TASK_SOURCE = "auto-import";

//
// The whole device photo library, which is what is watched before the user chooses albums.
//
export const WHOLE_LIBRARY_SOURCES: IAutoImportSource[] = [
    { type: "device-album", albumId: ALL_DEVICE_MEDIA_ALBUM_ID },
];

//
// What the app should do about automatic import right now.
//
export interface IMobileAutoImportPlan {
    // Whether the automatic import task should be running at all.
    shouldRun: boolean;

    // The sandbox-relative path of the database automatic import writes to.
    databasePath: string;

    // True when no default database has been chosen yet, so the path above is where a new one goes.
    isNewDefault: boolean;

    // The settings the task should run with.
    settings: IAutoImportSettings;
}

//
// Decides what the app should do about automatic import.
//
// When the user has switched automatic import on but named no albums, the whole photo library is
// watched. Running with no sources at all would import nothing while looking like it was working,
// which is the worst of both.
//
export function planMobileAutoImport(
    storedSettings: IAutoImportSettings | undefined,
    defaultDatabasePath: string | undefined
): IMobileAutoImportPlan {
    const settings = normaliseAutoImportSettings(storedSettings);

    if (settings.sources.length === 0) {
        settings.sources = WHOLE_LIBRARY_SOURCES;
    }

    const isNewDefault = defaultDatabasePath === undefined || defaultDatabasePath.length === 0;

    return {
        shouldRun: settings.enabled,
        databasePath: isNewDefault ? DEFAULT_DATABASE_FOLDER_NAME : defaultDatabasePath!,
        isNewDefault,
        settings,
    };
}
