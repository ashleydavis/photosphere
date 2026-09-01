//
// The one sync the mobile WebView still starts: the one after an edit made in the app.
//
// This is what is left of the mobile sync scheduler. The scheduler held a ten second debounce timer
// and a five minute periodic timer, and both were stopped by the operating system the moment the app
// left the screen, which is why syncing has moved to a loop on the native side. That loop pushes the
// database automatic import writes to, whether or not the app is on screen, and nothing in the
// WebView drives it.
//
// What the native loop cannot cover is a database the user opened by hand: it is not recorded
// anywhere the loop can read, and it is open only while the app is on screen anyway. So an edit made
// in the app queues one sync for the database that edit was made in, once, at the moment it happens.
// There is no timer here and nothing periodic: the app being on screen and the user having just
// changed something is the whole trigger.
//

//
// The task type a sync is queued as, registered by the mobile worker entry.
//
export const SYNC_TASK_TYPE = "sync-database";

//
// The input payload for a sync-database task. Only the database path is needed; the worker resolves
// the origin from the database config itself.
//
export interface ISyncTaskData {
    // The local path of the database to sync.
    databasePath: string;
}

//
// What the decision to sync after an edit is made from.
//
export interface IEditSyncInputs {
    //
    // Whether an automatic sync is permitted at all, as computeSyncAllowed decides it: syncing
    // switched on, a network, and not a cellular connection while the Wi-Fi-only restriction is on.
    //
    syncAllowed: boolean;

    //
    // The path of the open database, or undefined when none is open.
    //
    databasePath: string | undefined;

    //
    // Whether a sync of that database is already running. A second one would queue behind the first
    // holding an engine slot, and would then find nothing to do.
    //
    syncInFlight: boolean;
}

//
// Whether an edit should start a sync right now.
//
// Whether syncing is permitted is checked here rather than assumed by the caller, because this is the
// only place left in the WebView that starts a sync: losing that check would mean an edit pushed
// photos over a cellular connection after the user had asked it not to.
//
export function shouldSyncAfterEdit(inputs: IEditSyncInputs): boolean {
    if (!inputs.syncAllowed) {
        return false;
    }
    if (inputs.databasePath === undefined || inputs.databasePath.length === 0) {
        return false;
    }
    if (inputs.syncInFlight) {
        return false;
    }
    return true;
}
