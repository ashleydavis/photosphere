import {
    ALL_DEVICE_MEDIA_ALBUM_ID,
    IAutoImportSettings,
    IAutoImportSource,
    normaliseAutoImportSettings,
} from "api/src/lib/auto-import-settings";

//
// What the mobile app should do about automatic import, worked out from its settings alone.
//
// This mirrors the desktop planner (packages/node-api/src/lib/auto-import-desktop.ts): the decisions
// live here as plain functions so they can be unit tested, and the provider is left with the parts
// that need the app (creating the database, starting the task, asking for the permission).
//

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
