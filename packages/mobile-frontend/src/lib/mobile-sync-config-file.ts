import { TaskQueue, TaskStatus, TaskPriority } from "task-queue";
import { RandomUuidGenerator } from "utils";
import { normaliseSyncSettings, resolveSyncPauseMs, type ISyncFile, type ISyncSettings } from "api/src/lib/sync-settings";
import { SYNC_CONFIG_PATH } from "api/src/lib/mobile-config-paths";
import type { ISyncConfigFile, ISyncFileContents } from "./mobile-sync-file";

//
// Reads and writes the mobile sync.toml.
//
// The same arrangement as mobile-auto-import-config-file.ts, and for the same reason: the WebView
// has no filesystem access, so the file is reached through the embedded worker's read-sync-config /
// write-sync-config tasks, which run over the same storage layer the databases themselves are read
// through.
//

//
// Prefix of the source tag for the settings tasks.
//
// Each task gets its own source rather than sharing one, because shutting a TaskQueue down cancels
// every task under its source: with a shared tag, two reads in flight at once would cancel each
// other and one would come back with no result.
//
const SYNC_CONFIG_TASK_SOURCE_PREFIX = "sync-config";

//
// The outputs of the read-sync-config worker task.
//
interface IReadSyncConfigOutputs {
    // The settings, already filled from the defaults by the handler.
    settings?: ISyncSettings;

    // The database the background sync pushes.
    databasePath?: string;

    // The gap between background sync passes, in milliseconds.
    pauseBetweenRunsMs?: number;

    // Whether the file was there at all.
    exists?: boolean;
}

//
// Runs one settings task and returns its outputs, throwing when it fails so the caller surfaces a
// real error rather than silently reading or writing nothing.
//
async function runSyncConfigTask(type: string, data: object): Promise<IReadSyncConfigOutputs> {
    const uuidGenerator = new RandomUuidGenerator();
    const queue = new TaskQueue(uuidGenerator, `${SYNC_CONFIG_TASK_SOURCE_PREFIX}-${uuidGenerator.generate()}`);
    try {
        // Interactive: the settings card cannot render until this comes back, so it must not sit
        // behind whatever the background loops have already queued.
        const taskId = queue.addTask(type, data, undefined, TaskPriority.Interactive);
        const result = await queue.awaitTask(taskId);
        if (!result || result.status === TaskStatus.Failed) {
            throw new Error(`${type} failed: ${result?.errorMessage ?? "no result"}`);
        }
        return (result.outputs ?? {}) as IReadSyncConfigOutputs;
    }
    finally {
        queue.shutdown();
    }
}

//
// The sync.toml accessor the mobile settings functions run on.
//
export const mobileSyncConfigFile: ISyncConfigFile = {
    //
    // Reads sync.toml, reporting whether the file was there.
    //
    async read(): Promise<ISyncFileContents> {
        const outputs = await runSyncConfigTask("read-sync-config", { configPath: SYNC_CONFIG_PATH });
        return {
            settings: normaliseSyncSettings(outputs.settings),
            databasePath: outputs.databasePath,
            pauseBetweenRunsMs: resolveSyncPauseMs(outputs.pauseBetweenRunsMs),
            exists: outputs.exists === true,
        };
    },

    //
    // Writes sync.toml, replacing its contents.
    //
    async write(contents: ISyncFile): Promise<void> {
        await runSyncConfigTask("write-sync-config", {
            configPath: SYNC_CONFIG_PATH,
            settings: contents.settings,
            databasePath: contents.databasePath,
            pauseBetweenRunsMs: contents.pauseBetweenRunsMs,
        });
    },
};
