import * as path from "path";
import { IAutoImportSettings, IAutoImportSource, IFolderAutoImportSource, normaliseAutoImportSettings } from "api";
import { IDesktopConfig } from "./desktop-config";

//
// What the desktop app should do about automatic import, worked out from its config alone.
//
// The decisions live here rather than in the Electron main process so they can be unit tested: the
// main process is left with the parts that genuinely need Electron (where the application data
// directory is) and the parts that need the worker pool (creating the database, starting the task).
//

//
// The folder the default private database is created in, under the application data directory.
//
export const DEFAULT_DATABASE_FOLDER_NAME = "photosphere-default";

//
// The name the default private database is listed under.
//
export const DEFAULT_DATABASE_DISPLAY_NAME = "My Photos";

//
// The source tag every automatic import task is queued under, so it can be cancelled as a group
// when the setting is switched off or the app quits.
//
export const AUTO_IMPORT_TASK_SOURCE = "auto-import";

//
// What the main process should do about automatic import right now.
//
export interface IDesktopAutoImportPlan {
    // Whether the automatic import task should be running at all.
    shouldRun: boolean;

    // The database automatic import writes to.
    databasePath: string;

    // True when no default database has been chosen yet, so the path above is where a new one goes.
    isNewDefault: boolean;

    // The settings the task should run with.
    settings: IAutoImportSettings;
}

//
// Turns the operating system's photo folders into watched sources.
//
export function foldersAsSources(folderPaths: string[]): IFolderAutoImportSource[] {
    return folderPaths.map(folderPath => ({
        type: "folder",
        path: folderPath,
        recurse: true,
    }));
}

//
// Where the default private database goes when the user has not chosen one.
//
export function getDefaultDatabasePath(appDataPath: string): string {
    return path.join(appDataPath, DEFAULT_DATABASE_FOLDER_NAME);
}

//
// Decides what the main process should do about automatic import.
//
// When the user has switched automatic import on but named no places to watch, the operating
// system's own photo folders are used. Running with no sources at all would import nothing while
// looking like it was working, which is the worst of both.
//
export function planDesktopAutoImport(
    config: IDesktopConfig,
    defaultPhotoFolders: string[],
    appDataPath: string
): IDesktopAutoImportPlan {
    const storedSources: IAutoImportSource[] = config.autoImportSources ?? [];
    const settings = normaliseAutoImportSettings({
        enabled: config.autoImportEnabled,
        sources: storedSources,
    });

    if (settings.sources.length === 0) {
        settings.sources = foldersAsSources(defaultPhotoFolders);
    }

    const isNewDefault = config.defaultDatabasePath === undefined || config.defaultDatabasePath.length === 0;

    return {
        // Nothing to watch means nothing to run. The interface says so; the task would throw.
        shouldRun: settings.enabled && settings.sources.length > 0,
        databasePath: isNewDefault ? getDefaultDatabasePath(appDataPath) : config.defaultDatabasePath!,
        isNewDefault,
        settings,
    };
}
