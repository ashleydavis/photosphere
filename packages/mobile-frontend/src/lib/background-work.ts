//
// What the app should ask the native side to run in the background.
//
// Two features run there and they are switched on separately: automatic import takes photos in, and
// syncing pushes what is in the database to its origin. Either one on is a reason to run the
// background work; both off is the only reason not to.
//
// They were briefly tied together, so syncing in the background needed automatic import switched on
// as well. That was a consequence of both loops living in one Android foreground service and nobody
// deciding what should start it, not something anybody asked for: a user who imports by hand and
// wants their edits pushed is not asking for their photo library to be scanned.
//
// This is a plain function rather than something in the provider, so the rule can be tested.
//

//
// The two settings the decision is made from.
//
export interface IBackgroundWorkInputs {
    //
    // Whether automatic import is switched on.
    //
    autoImportEnabled: boolean;

    //
    // Whether syncing is switched on.
    //
    syncEnabled: boolean;

    //
    // Whether there is a database for the background sync to push at all.
    //
    // Syncing being switched on is not by itself a reason to run anything: a phone that has never
    // opened a database has nothing to push, and starting a service for it would put an ongoing
    // notification on the screen of every fresh install to do nothing.
    //
    hasDatabaseToSync: boolean;
}

//
// What to do about the native background work.
//
export interface IBackgroundWorkDecision {
    //
    // Whether the native side should be running the background work at all. False means stop it.
    //
    shouldRun: boolean;

    //
    // Whether the photo library permission has to be granted before it starts.
    //
    // Only automatic import reads the photo library. Syncing moves what is already in the database,
    // so a phone that only syncs must never be asked for access to its photos.
    //
    needsMediaPermission: boolean;
}

//
// Decides what the native side should be running.
//
export function planBackgroundWork(inputs: IBackgroundWorkInputs): IBackgroundWorkDecision {
    const syncingHasWork = inputs.syncEnabled && inputs.hasDatabaseToSync;

    return {
        shouldRun: inputs.autoImportEnabled || syncingHasWork,
        needsMediaPermission: inputs.autoImportEnabled,
    };
}
