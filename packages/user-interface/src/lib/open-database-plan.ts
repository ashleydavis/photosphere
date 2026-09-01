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
