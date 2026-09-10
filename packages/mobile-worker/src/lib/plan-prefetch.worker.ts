import type { ITaskContext } from "task-queue";
import { computeSyncAllowed } from "api/src/lib/sync-gate";
import type { ISyncSettings } from "api/src/lib/sync-settings";
import type { IPrefetchDatabaseData } from "node-api/src/lib/prefetch-database.worker";
import { readConfigFromStorage } from "node-api/src/lib/config.worker";
import { loadDatabaseConfig } from "api/src/lib/database-config";
import { openStorage } from "node-api/src/lib/open-storage";
import { isDatabasePartial } from "node-api/src/lib/media-file-database";
import { readNetworkConnectionType } from "../shims/network-status";

//
// The task that decides whether a background prefetch pass should run, and against which database.
//
// A prefetch fills in a partial replica: it walks the origin's thumbnails and database index files
// and copies down whatever the replica is missing. Until now the only thing that ever queued one was
// the end of a load-assets run, so a prefetch that failed part way was never tried again and the
// replica it was filling in stayed unfinished. A sync cannot repair that, because a sync copies what
// the difference between two merkle trees shows and a partial replica's tree is already identical to
// its origin's: a missing file is invisible to it.
//
// This is the same division of labour as plan-sync and plan-auto-import. The native loop asks what to
// do and forwards the tasks it is handed, so the settings format is parsed in one place, in
// TypeScript, and the two platforms cannot drift apart by assembling a payload differently.
//
// It obeys the sync settings rather than getting its own. This is network traffic to the origin on
// the user's connection, and a user who switches syncing off means stop using my data for this
// database. Reusing them also means no new configuration key, no wiki change, and one rule to keep in
// step instead of two. The prefetch that load-assets queues is deliberately not made to obey them,
// because that one is the user opening the database in front of them.
//

//
// One task a pass runs, in the order it is given.
//
export interface IPrefetchPassStep {
    // The task type to queue.
    type: string;

    // The input data to queue it with.
    data: object;
}

//
// The outputs of the plan-prefetch task: what a pass should do right now.
//
export interface IPrefetchPlanResult {
    // Whether a prefetch should run at all. False means this pass does nothing; the loop waits and
    // asks again, because every reason to refuse can go away without the app being touched.
    shouldRun: boolean;

    // The sandbox-relative path of the database a pass fills in, empty when there is not one.
    databasePath: string;

    // Why a prefetch is not running, for the log. Empty when one is.
    reason: string;

    // The settings the decision was made with.
    settings: ISyncSettings;

    // How long to wait after a pass finishes before starting the next one, in milliseconds.
    pauseBetweenRunsMs: number;

    // The tasks the pass runs, in order. Empty when shouldRun is false.
    steps: IPrefetchPassStep[];
}

//
// Builds the answer for a pass that is not going to run.
//
// Every refusal comes back with the pacing filled in, because the loop waits that long before asking
// again. A refusal with no gap would have it ask as fast as the engine could answer.
//
function refuse(reason: string, settings: ISyncSettings, pauseBetweenRunsMs: number): IPrefetchPlanResult {
    return {
        shouldRun: false,
        databasePath: "",
        reason,
        settings,
        pauseBetweenRunsMs,
        steps: [],
    };
}

//
// Handler for the plan-prefetch task.
//
export async function planPrefetchHandler(_data: object, _context: ITaskContext): Promise<IPrefetchPlanResult> {
    const { config } = await readConfigFromStorage("config.yaml");
    const syncConfig = config.sync;
    const settings = syncConfig.settings;
    const pauseBetweenRunsMs = syncConfig.pauseBetweenRunsMs;

    // The master switch first, and on its own, exactly as plan-sync applies it. It is what a user
    // reaches for when they want the app to stop using their connection for this database.
    if (!settings.enabled) {
        return refuse("syncing is switched off", settings, pauseBetweenRunsMs);
    }

    const connectionType = readNetworkConnectionType();

    // The same rule the interface applies, from the same function.
    const allowed = computeSyncAllowed({
        syncEnabled: settings.enabled,
        syncOnlyOnWifi: settings.onlyOnWifi,
        connected: connectionType !== "none",
        connectionType,
    });

    if (!allowed) {
        return refuse(`the connection is "${connectionType}" and syncing is not allowed on it`, settings, pauseBetweenRunsMs);
    }

    // The database the app last opened, and failing that the one automatic import writes to. The
    // same resolution plan-sync makes, for the same reasons.
    const autoImportConfig = config.autoImport;
    const recordedPath = syncConfig.databasePath;
    const databasePath = recordedPath !== undefined && recordedPath.length > 0
        ? recordedPath
        : autoImportConfig.defaultDatabasePath;
    if (databasePath === undefined || databasePath.length === 0) {
        return refuse("no database has been opened to fill in", settings, pauseBetweenRunsMs);
    }

    // A database with no origin has nothing to fetch from.
    const { rawStorage } = await openStorage(databasePath);
    const databaseConfig = await loadDatabaseConfig(rawStorage);
    if (!databaseConfig?.origin) {
        return refuse(`"${databasePath}" has no origin to fill in from`, settings, pauseBetweenRunsMs);
    }

    // And a full database has nothing missing. The prefetch task itself checks this and returns, but
    // it would pay for an engine slot and a merkle tree load to find out, every pass, for as long as
    // the phone was switched on.
    if (!await isDatabasePartial(databasePath)) {
        return refuse(`"${databasePath}" is not a partial replica, so there is nothing to fill in`, settings, pauseBetweenRunsMs);
    }

    return {
        shouldRun: true,
        databasePath,
        reason: "",
        settings,
        pauseBetweenRunsMs,
        steps: [
            {
                // One prefetch task per pass, the same task load-assets queues when a database is
                // opened. It works out what is missing for itself.
                type: "prefetch-database",
                data: {
                    databasePath,
                    // Named here rather than natively, so a phone's job row reads the same whatever
                    // queued it. No cancel source: the pass is queued by the native driver under a
                    // source the WebView never learns, and it is switched off from Settings rather
                    // than stopped from the job list.
                    job: {
                        id: `prefetch:${databasePath}`,
                        name: "Filling in this database",
                    },
                } satisfies IPrefetchDatabaseData,
            },
        ],
    };
}
