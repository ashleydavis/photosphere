import type { ISyncFile, ISyncSettings } from "api/src/lib/sync-settings";
import { INITIAL_SYNC_SETTINGS, normaliseSyncSettings, resolveSyncPauseMs } from "api/src/lib/sync-settings";

//
// What a phone runs in the background, and the decisions the page takes about it: whether to start the work, whether the photo
// library permission lets automatic import stay on, and what the syncing settings of a fresh install and of a newly opened database
// should be. They are plain functions so they can be tested.
//
// Two features run in the background and they are switched on separately: automatic import takes photos in, and syncing pushes what is
// in the database to its origin. Either one on is a reason to run the background work; both off is the only reason not to.
//

//
// The two settings the decision is made from.
//
export interface IBackgroundWorkInputs {
    // Whether automatic import is switched on.
    autoImportEnabled: boolean;

    // Whether syncing is switched on.
    syncEnabled: boolean;

    // Whether there is a database for the background sync to push at all. Syncing being switched on is not by itself a reason to run
    // anything: a phone that has never opened a database has nothing to push, and starting the work for it would put an ongoing
    // notification on the screen of every fresh install to do nothing.
    hasDatabaseToSync: boolean;
}

//
// What to do about the background work.
//
export interface IBackgroundWorkDecision {
    // Whether the background work should be running at all. False means stop it.
    shouldRun: boolean;

    // Whether the photo library permission has to be granted before it starts. Only automatic import reads the photo library. Syncing
    // moves what is already in the database, so a phone that only syncs is never asked for access to its photos.
    needsMediaPermission: boolean;
}

//
// Decides what the background work should be doing.
//
export function planBackgroundWork(inputs: IBackgroundWorkInputs): IBackgroundWorkDecision {
    const syncingHasWork = inputs.syncEnabled && inputs.hasDatabaseToSync;

    return {
        shouldRun: inputs.autoImportEnabled || syncingHasWork,
        needsMediaPermission: inputs.autoImportEnabled,
    };
}

//
// What the phone said when asked for the photo library permission.
//
export type MediaPermissionState = "granted" | "partial" | "denied" | "unavailable";

//
// What the app should do about a permission answer.
//
export interface IMediaPermissionOutcome {
    // Whether automatic import may stay switched on.
    enabled: boolean;

    // What to tell the user, or undefined when there is nothing to say because it was granted.
    message: string | undefined;
}

//
// What to tell a user whose device cannot offer the photo library at all.
//
export const MEDIA_PERMISSION_UNAVAILABLE_MESSAGE =
    "This device does not offer access to a photo library, so automatic import cannot watch one.";

//
// What to tell a user who refused the photo library permission.
//
export const MEDIA_PERMISSION_DENIED_MESSAGE =
    "Photosphere needs permission to read your photos before it can import them automatically. "
    + "Grant photo access in your device settings, under Apps, Photosphere, Permissions.";

//
// What to tell a user who let the app see only the photos they picked. Android 14 and later offer that as a third answer. It is not
// enough for automatic import, which is there to back the library up rather than a handful of photos, so it is said separately from a
// refusal: the user has granted something, and what they have to change is which photos rather than whether the app may see any.
//
export const MEDIA_PERMISSION_PARTIAL_MESSAGE =
    "Photosphere can see only the photos you picked, so it cannot back up the rest of your library. "
    + "Choose \"Allow all\" for photo access in your device settings, under Apps, Photosphere, Permissions.";

//
// Decides whether automatic import may stay on, and what to say about it. A refusal switches the setting back off rather than leaving
// it on and silently importing nothing: a user who sees the switch in the on position is entitled to believe their photos are being
// backed up.
//
export function resolveMediaPermission(state: MediaPermissionState): IMediaPermissionOutcome {
    if (state === "granted") {
        return {
            enabled: true,
            message: undefined,
        };
    }

    if (state === "unavailable") {
        return {
            enabled: false,
            message: MEDIA_PERMISSION_UNAVAILABLE_MESSAGE,
        };
    }

    if (state === "partial") {
        return {
            enabled: false,
            message: MEDIA_PERMISSION_PARTIAL_MESSAGE,
        };
    }

    return {
        enabled: false,
        message: MEDIA_PERMISSION_DENIED_MESSAGE,
    };
}

//
// The answer to the permission request as the phone gives it, before it has been checked.
//
export interface IRawPermissionResult {
    // Whether the user granted the photo library permission.
    granted?: boolean;

    // Whether the user let the app see only the photos they picked. Android 14 and later only.
    partial?: boolean;
}

//
// Reads a permission answer out of whatever the phone returned. An answer that is not one of the states it is supposed to return is
// treated as a refusal rather than as permission: reading "granted" into an answer nobody understood is how an app ends up trying to
// read photos it was never allowed to see.
//
export function readPermissionState(result: IRawPermissionResult | null | undefined): MediaPermissionState {
    if (!result) {
        return "unavailable";
    }

    if (result.granted === true) {
        return "granted";
    }

    // Read before the refusal below, because a partial grant arrives with granted false: the app has some access, and saying it has
    // none would send the user looking for a permission they have already given.
    if (result.partial === true) {
        return "partial";
    }

    return "denied";
}

//
// What the syncing section holds, and whether it has ever been written.
//
// The two are different questions and both are needed: a section nobody has written reads as syncing off, which is the right answer for
// a background loop that would otherwise push over a metered connection on a guess, and the wrong one to put in front of a new user
// whose toggles say on.
//
export interface IMobileSyncSettings {
    // The settings, already filled from the defaults by the reader.
    settings: ISyncSettings;

    // The database the background sync pushes, or undefined when none has been opened yet.
    databasePath: string | undefined;

    // The gap between background sync passes, in milliseconds.
    pauseBetweenRunsMs: number;

    // Whether the syncing settings have ever been written. It is the section and not the file: automatic import writing its own
    // section brings the file into being, and answering for the file would tell a fresh install that its syncing settings had already
    // been chosen, leaving syncing off on a phone whose toggles say it is on.
    written: boolean;
}

//
// What the syncing section should become when a fresh installation is seeded, or undefined to leave it exactly as it is. A section
// that has been written is left alone: overwriting it would put syncing back on for somebody who had switched it off, every time the
// app started.
//
export function planSyncSeed(current: IMobileSyncSettings): ISyncFile | undefined {
    if (current.written) {
        return undefined;
    }

    return {
        settings: { ...INITIAL_SYNC_SETTINGS },
        databasePath: current.databasePath,
        pauseBetweenRunsMs: resolveSyncPauseMs(current.pauseBetweenRunsMs),
    };
}

//
// What the syncing section should become when a database is opened, or undefined to leave it as it is. Recording it is what makes
// background syncing work for the database the user is actually using. The same path again is left alone rather than rewritten: a
// database is opened on every launch and on every switch between databases.
//
export function planSyncDatabase(current: IMobileSyncSettings, databasePath: string): ISyncFile | undefined {
    if (current.databasePath === databasePath) {
        return undefined;
    }

    return {
        settings: current.written
            ? normaliseSyncSettings(current.settings)
            : { ...INITIAL_SYNC_SETTINGS },
        databasePath,
        pauseBetweenRunsMs: resolveSyncPauseMs(current.pauseBetweenRunsMs),
    };
}
