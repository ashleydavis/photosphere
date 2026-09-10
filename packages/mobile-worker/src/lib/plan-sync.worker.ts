import type { ITaskContext } from "task-queue";
import { computeSyncAllowed } from "api/src/lib/sync-gate";
import type { ISyncSettings } from "api/src/lib/sync-settings";
import type { ISyncDatabaseData } from "api/src/lib/sync-database.types";
import { readConfigFromStorage } from "node-api/src/lib/config.worker";
import { loadDatabaseConfig } from "api/src/lib/database-config";
import { openStorage } from "node-api/src/lib/open-storage";
import { readNetworkConnectionType } from "../shims/network-status";

//
// The task that decides whether a background sync pass should run, and against which database.
//
// The native background sync (the Android foreground service's loop, and the iOS driver) has to know
// whether syncing is switched on, whether this connection is one it may use, and which database has
// a remote to push to. It asks this task rather than reading the settings file itself, so the file
// format is defined and parsed in exactly one place, in TypeScript, rather than once per platform in
// a native language.
//
// It hands back the task a pass has to run, ready to queue, rather than the pieces a caller would
// assemble it from. Native code then forwards it unchanged and never builds a task payload of its
// own, so what a pass does is decided and tested here, and the two platforms cannot drift apart by
// assembling it differently. The same division as plan-auto-import.
//
// The deciding is computeSyncAllowed, which the app's own interface uses, so the background loop and
// the interface cannot disagree about whether an automatic sync is permitted. A second copy of that
// rule would be a second thing to keep in step, and the failure when they drift is somebody's mobile
// data bill.
//

//
// What the native prefetch loop's last pass said about the replica, as it arrives here.
//
// The native side reports the fact and this task decides what it means, which is the same division as
// the connection type: the platform says "wifi" or "cellular" and computeSyncAllowed decides. Only
// "working" holds a sync back, because the question is whether the prefetch is making progress rather
// than whether it has finished: a sync that waited for a prefetch that cannot finish would be a phone
// that has silently stopped backing up, which is worse than the contention it was avoiding.
//
export type PrefetchState = "unknown" | "working" | "stalled" | "complete";

//
// The inputs of the plan-sync task.
//
export interface IPlanSyncData {
    // What the prefetch loop's last pass said about the replica. Absent, or a value this build does
    // not recognise, is read as "unknown" and allows syncing: nothing about a value nobody understood
    // should be able to stop a phone syncing.
    prefetchState?: PrefetchState;
}

//
// One task a pass runs, in the order it is given.
//
export interface ISyncPassStep {
    // The task type to queue.
    type: string;

    // The input data to queue it with.
    data: object;
}

//
// The outputs of the plan-sync task: what a pass should do right now.
//
export interface IPlanSyncResult {
    // Whether a sync should run at all. False means this pass does nothing; the loop waits and asks
    // again, because every reason to refuse can go away without the app being touched.
    shouldRun: boolean;

    // The sandbox-relative path of the database a pass syncs, empty when there is not one.
    databasePath: string;

    // Why a sync is not running, for the log. Empty when one is.
    reason: string;

    // The settings the decision was made with.
    settings: ISyncSettings;

    // How long to wait after a pass finishes before starting the next one, in milliseconds.
    pauseBetweenRunsMs: number;

    // The tasks the pass runs, in order. Empty when shouldRun is false.
    steps: ISyncPassStep[];
}

//
// Builds the answer for a pass that is not going to run.
//
// Every refusal comes back with the pacing filled in, because the loop waits that long before asking
// again. A refusal with no gap would have it ask as fast as the engine could answer.
//
function refuse(reason: string, settings: ISyncSettings, pauseBetweenRunsMs: number): IPlanSyncResult {
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
// Handler for the plan-sync task.
//
export async function planSyncHandler(data: IPlanSyncData, _context: ITaskContext): Promise<IPlanSyncResult> {
    // One read for both sections. They used to be two files, so resolving which database to push
    // meant opening sync.toml and then auto-import.toml; the merged file costs one read per pass.
    const { config } = await readConfigFromStorage("config.yaml");
    const syncConfig = config.sync;
    const settings = syncConfig.settings;
    const pauseBetweenRunsMs = syncConfig.pauseBetweenRunsMs;

    // The master switch first, and on its own. It is what a user reaches for when they want syncing
    // to stop, so nothing below can get past it and it is not mixed in with anything else.
    if (!settings.enabled) {
        return refuse("syncing is switched off", settings, pauseBetweenRunsMs);
    }

    const connectionType = readNetworkConnectionType();

    // The same rule the interface applies, from the same function. "connected" is derived from the
    // connection type rather than asked for separately: the platform reports one thing here, and a
    // type of "none" is what having no connection looks like.
    const allowed = computeSyncAllowed({
        syncEnabled: settings.enabled,
        syncOnlyOnWifi: settings.onlyOnWifi,
        connected: connectionType !== "none",
        connectionType,
    });

    if (!allowed) {
        return refuse(`the connection is "${connectionType}" and syncing is not allowed on it`, settings, pauseBetweenRunsMs);
    }

    // After the master switch and the connection, and before the database is resolved, because the
    // reason a user is most likely to care about should win: a phone on cellular is refused for being
    // on cellular rather than for waiting on a prefetch.
    //
    // Only "working" waits. A prefetch that is stuck, one that has finished, and a state nobody has
    // reported yet all let the sync run, because the alternative is a sync that never happens again:
    // measured on a Pixel 6, a prefetch failed and was never retried, and a sync that had waited for
    // it would have waited for the life of the app. Reaching the origin's merkle tree during a pass
    // that overlapped a working prefetch took 81.5 seconds against 97 milliseconds when the phone was
    // idle, and the record merge in that pass took 15 minutes pulling down the same metadata shards
    // the prefetch was fetching, which is what waiting one gap avoids.
    if (data?.prefetchState === "working") {
        return refuse("a prefetch is still filling this database in", settings, pauseBetweenRunsMs);
    }

    // The database the app last opened, and failing that the one automatic import writes to.
    //
    // The opened one comes first because it is what the user is actually using, and because syncing
    // must not need automatic import switched on to have anything to push: the two are switched on
    // separately. The import's database is the fallback for a phone that has imported in the
    // background without anybody opening it.
    const autoImportConfig = config.autoImport;
    const recordedPath = syncConfig.databasePath;
    const databasePath = recordedPath !== undefined && recordedPath.length > 0
        ? recordedPath
        : autoImportConfig.defaultDatabasePath;
    if (databasePath === undefined || databasePath.length === 0) {
        return refuse("no database has been opened to sync", settings, pauseBetweenRunsMs);
    }

    // A database with no origin has nowhere to sync to. The sync task itself would skip it, having
    // paid for an engine slot and a database open to find that out, and it would say so every pass
    // for as long as the phone was switched on.
    const { rawStorage } = await openStorage(databasePath);
    const databaseConfig = await loadDatabaseConfig(rawStorage);
    if (!databaseConfig?.origin) {
        return refuse(`"${databasePath}" has no origin to sync to`, settings, pauseBetweenRunsMs);
    }

    return {
        shouldRun: true,
        databasePath,
        reason: "",
        settings,
        pauseBetweenRunsMs,
        steps: [
            {
                // One sync task per pass, the same task the app queues when the user asks for a sync
                // and the same one the desktop's timer queues. It works out what to move for itself,
                // and early-outs when both sides already hold the same content.
                type: "sync-database",
                data: {
                    databasePath,
                    // Named here rather than natively, so a phone's sync row reads the same as a
                    // desktop's. No cancel source: the pass is queued by the native driver under a
                    // source of its own that the WebView never learns, and syncing is switched off
                    // from Settings rather than stopped from the job list.
                    job: {
                        id: `sync:${databasePath}`,
                        name: "Syncing database",
                    },
                } satisfies ISyncDatabaseData,
            },
        ],
    };
}
