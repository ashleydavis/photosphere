import type { ITaskContext } from "task-queue";
import { computeSyncAllowed } from "api/src/lib/sync-gate";
import { AUTO_IMPORT_CONFIG_PATH, SYNC_CONFIG_PATH } from "api/src/lib/mobile-config-paths";
import type { ISyncSettings } from "api/src/lib/sync-settings";
import { readAutoImportConfigFile } from "node-api/src/lib/auto-import-config.worker";
import { readSyncConfigFile } from "node-api/src/lib/sync-config.worker";
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
export async function planSyncHandler(_data: object, _context: ITaskContext): Promise<IPlanSyncResult> {
    const syncConfig = await readSyncConfigFile(SYNC_CONFIG_PATH);
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

    // The database the app last opened, and failing that the one automatic import writes to.
    //
    // The opened one comes first because it is what the user is actually using, and because syncing
    // must not need automatic import switched on to have anything to push: the two are switched on
    // separately. The import's database is the fallback for a phone that has imported in the
    // background without anybody opening it.
    const autoImportConfig = await readAutoImportConfigFile(AUTO_IMPORT_CONFIG_PATH);
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
                },
            },
        ],
    };
}
