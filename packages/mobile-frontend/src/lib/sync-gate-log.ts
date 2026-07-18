import { log } from "utils";

//
// Logs the sync-gate decision in the same format as the desktop main process so
// shared smoke tests can wait_for_log("Sync gate set to …") on every platform.
//
export function logSyncGate(allowed: boolean): void {
    log.info(`Sync gate set to ${allowed}`);
}
