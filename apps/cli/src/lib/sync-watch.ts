import pc from "picocolors";
import { log } from "utils";
import type { ISyncResult } from "node-api";

//
// The watching half of `psi sync`.
//
// `psi sync` pushes what has changed to the origin once. `psi sync --watch` keeps doing it. Run it
// beside `psi add --watch` and that is what `psi watch` used to be, except that each half is
// separately useful and separately testable, where before it was both or neither.
//

//
// How long to wait between syncs when none is asked for, in seconds.
//
export const DEFAULT_SYNC_WATCH_INTERVAL_SECONDS = 30;

//
// Reads the interval a watch was asked to run at, in seconds.
//
// Throws rather than falling back to the default, because a mistyped interval that silently syncs
// every thirty seconds instead of every hour is exactly the kind of thing nobody notices.
//
export function parseWatchInterval(interval: string | undefined): number {
    if (interval === undefined) {
        return DEFAULT_SYNC_WATCH_INTERVAL_SECONDS;
    }

    const seconds = Number(interval);
    if (!Number.isFinite(seconds) || seconds <= 0) {
        throw new Error(`--interval must be a positive number of seconds, got "${interval}".`);
    }

    return seconds;
}

//
// What a sync watch needs to run.
//
export interface ISyncWatchOptions {
    // How long to wait between syncs, in seconds.
    intervalSeconds: number;

    // Runs one sync and reports whether anything was transferred.
    syncOnce: () => Promise<ISyncResult>;

    // True once the watch should stop. Passed in rather than reached for, so the loop can be tested
    // without sending a signal to the test runner.
    isStopped: () => boolean;
}

//
// Syncs over and over until it is told to stop.
//
// A sync that fails is reported and the watch carries on: a network that is down now may be up in
// thirty seconds, and stopping would mean nothing syncs again until someone notices.
//
export async function runSyncWatch(options: ISyncWatchOptions): Promise<void> {
    log.info(pc.bold(`Syncing every ${options.intervalSeconds} second(s). Press Ctrl-C to stop.`));

    while (!options.isStopped()) {
        try {
            const result = await options.syncOnce();
            if (result.synced) {
                log.info("Sync completed successfully!");
            }
        }
        catch (error: any) {
            log.error(pc.red(`✗ Sync failed: ${error.message}`));
        }

        if (options.isStopped()) {
            break;
        }

        await new Promise<void>(resolve => setTimeout(resolve, options.intervalSeconds * 1000));
    }
}
