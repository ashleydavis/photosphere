//
// What openDatabase knows when it is asked to open a database, after the existence check has come
// back and immediately before it acts.
//
export interface IOpenDatabaseInputs {
    //
    // The database currently open, or undefined when none is.
    //
    openDatabasePath: string | undefined;

    //
    // The database being opened.
    //
    requestedDatabasePath: string;

    //
    // The database a load is running for right now, or undefined when no load is running. This is
    // read after an await on the existence check, so a load that was running when the user clicked
    // may already have finished by the time it is read.
    //
    loadingDatabasePath: string | undefined;
}

//
// What the effect that loads a database knows when React runs its cleanup, which is the render being
// replaced going away rather than anything the user did.
//
export interface ILoadTeardownInputs {
    //
    // The id of the load this effect started or claimed when it ran, or undefined when this render
    // had no database to load. Each load gets an id of its own, so this names one load and no other.
    //
    startedLoadId: string | undefined;

    //
    // The id of the load running right now, or undefined when no load is running. This is read at
    // cleanup time, so it may already be a load something else started.
    //
    currentLoadId: string | undefined;
}

//
// What openDatabase should do about the database that is already open.
//
export interface IOpenDatabasePlan {
    //
    // Whether to close the open database first. Closing cancels its load, empties the assets held in
    // memory and resets the gallery, so it must not happen to a database that is being reopened while
    // its own load is still running.
    //
    closeFirst: boolean;

    //
    // Whether to start the load directly rather than leaving it to the effect that watches the
    // database path. Reopening the database already open sets the path to the value it already holds,
    // so the effect does not re-run and nothing would reload.
    //
    startLoadDirectly: boolean;
}

//
// Decides what openDatabase does about the database already on screen.
//
// This is a plain function because getting it wrong empties the gallery in a way nothing recovers
// from, and it has done so twice. Both times the same test caught it: Electron smoke test 26,
// s3-database-lifecycle, waiting on "Gallery loaded: 2 assets" after the app restarts, restores the
// database it had open and starts loading it, and the test then opens that same database from the
// list a moment later.
//
// The three cases:
//
// Opening a different database, or opening one when none is open, closes what is there and lets the
// path change start the load, which is what it has always done.
//
// Reopening the database already open while its load is still running leaves it alone. Closing would
// cancel that load, and putting the same path straight back does not change the path, so whether
// anything replaced it came down to whether React had flushed the render for the undefined it was set
// to in between. Neither outcome of that coin toss is right.
//
// Reopening the database already open when its load has finished closes and reloads it, because that
// reload is what several smoke tests wait to see. The reload has to be started here: the path is
// being set to the value it already holds, so the effect that loads on a path change never re-runs.
// Leaving it to that effect is what failed on run 33455400870: the load was still running when the
// click landed, finished during the existence check that openDatabase awaits first, and so was over
// by the time this decision was made. The close wiped the two assets it had just loaded, the path
// never changed, no load replaced it, and the gallery reported 0 assets until the test gave up.
//
export function planOpenDatabase(inputs: IOpenDatabaseInputs): IOpenDatabasePlan {
    const reopeningTheOpenDatabase = inputs.openDatabasePath === inputs.requestedDatabasePath;
    const loadStillRunningForIt = reopeningTheOpenDatabase && inputs.loadingDatabasePath === inputs.requestedDatabasePath;

    if (loadStillRunningForIt) {
        return {
            closeFirst: false,
            startLoadDirectly: false,
        };
    }

    if (reopeningTheOpenDatabase && inputs.openDatabasePath !== undefined) {
        return {
            closeFirst: true,
            startLoadDirectly: true,
        };
    }

    return {
        closeFirst: inputs.openDatabasePath !== undefined,
        startLoadDirectly: false,
    };
}

//
// Whether the database-path effect should tear down a load when it is cleaned up.
//
// That effect tears its load down so a path change leaves nothing behind, but a reopen of the same
// database closes it and sets the path straight back, and nothing separates the two: the close empties
// the load, and the load that replaces it is started by openDatabase before React renders the path
// back. By the time the cleanup for the previous path runs, the load it finds is that replacement.
// Cancelling it kills the load the user is waiting on, and the effect then starts a second load as
// well, so two run at once against one database.
//
// This is here beside planOpenDatabase because it is the other half of the same reopen: that function
// decides to start the load from openDatabase, and this one keeps the effect from cancelling it. Smoke
// test 26, s3-database-lifecycle, showed both loads starting and both finishing with 0 assets.
//
// The comparison is by load id, not by database path. A reopen of the same database gives both loads
// the same path, so a path comparison says yes and cancels the replacement, which is the bug itself.
// An id belongs to one load, so a load this effect did not start is left alone whichever database it
// is for.
//
export function planLoadTeardown(inputs: ILoadTeardownInputs): boolean {
    if (inputs.startedLoadId === undefined) {
        return false;
    }

    return inputs.currentLoadId === inputs.startedLoadId;
}
