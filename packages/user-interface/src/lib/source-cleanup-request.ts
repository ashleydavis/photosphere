import { IAutoImportSettings } from "api/src/lib/auto-import-settings";

//
// Asking for the photos this device still holds that the database already has to be deleted.
//
// Deleting them raises a system confirmation on both mobile platforms, so it happens when the user
// asks for it rather than while photos are being imported: one walk, one set of dialogs, at a
// moment they chose. It used to happen inside automatic import, after every batch, which meant the
// user was asked once per handful of photos.
//
// The counting pass and the deleting pass are the same task with a flag, so what the button says it
// will delete is decided by exactly the code that then deletes it.
//

//
// What the cleanup task reports back.
//
export interface ICleanupSourcesTaskResult {
    // How many items on the device were looked at.
    considered: number;

    // The ids of the photos that are in the database and can go.
    deletableSourceIds: string[];

    // The ids of the photos that were deleted. Empty for a counting pass.
    deletedSourceIds: string[];

    // The ids the device refused or failed to delete.
    failedSourceIds: string[];
}

//
// The task data one cleanup run needs.
//
export interface ICleanupSourcesTaskData {
    // The database to check against.
    storageDescriptor: IStorageDescriptor;

    // Where to look: the same places automatic import watches.
    settings: IAutoImportSettings;

    // When true, count what could go without deleting any of it.
    dryRun: boolean;
}

//
// Names the database a task works on. Declared here rather than imported, because this package is
// shared with the web and mobile builds and must not depend on the Node-side task code.
//
export interface IStorageDescriptor {
    // The path of the database.
    databasePath: string;
}

//
// Builds the task data for one cleanup run.
//
export function buildCleanupSourcesTaskData(databasePath: string, settings: IAutoImportSettings, dryRun: boolean): ICleanupSourcesTaskData {
    return {
        storageDescriptor: { databasePath },
        settings,
        dryRun,
    };
}

//
// What the cleanup button should say, given what the last run found.
//
// Three states, and each one has to say something different, because "nothing happened" and "there
// was nothing to do" look identical to a user otherwise.
//
export function describeCleanupResult(result: ICleanupSourcesTaskResult | undefined, dryRun: boolean): string {
    if (result === undefined) {
        return "";
    }

    if (dryRun) {
        if (result.deletableSourceIds.length === 0) {
            return `Nothing to delete: none of the ${result.considered} photo(s) on this device are in your database yet.`;
        }
        return `${result.deletableSourceIds.length} of the ${result.considered} photo(s) on this device are in your database and can be deleted.`;
    }

    if (result.failedSourceIds.length > 0) {
        return `Deleted ${result.deletedSourceIds.length} photo(s). ${result.failedSourceIds.length} could not be deleted.`;
    }

    return `Deleted ${result.deletedSourceIds.length} photo(s) from this device.`;
}
