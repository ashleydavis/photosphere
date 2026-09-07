import { TaskQueue, TaskStatus, TaskPriority } from "task-queue";
import { RandomUuidGenerator } from "utils";
import { normaliseAutoImportSettings, type IAutoImportSettings } from "api/src/lib/auto-import-settings";
import { resolveAutoImportPauseMs, type IAutoImportFile } from "api/src/lib/auto-import-mobile";
import { normaliseSyncSettings, resolveSyncPauseMs, type ISyncFile, type ISyncSettings } from "api/src/lib/sync-settings";
import { CONFIG_PATH } from "api/src/lib/mobile-config-paths";
import type { IAutoImportConfigFile } from "./mobile-auto-import-file";
import type { ISyncConfigFile, ISyncFileContents } from "./mobile-sync-file";

//
// Reads and writes the mobile config.yaml.
//
// The same arrangement as mobile-databases-config-file.ts, and for the same reason: the WebView has
// no filesystem access, so the file is reached through the embedded worker's read-config /
// write-config tasks, which run over the same storage layer the databases themselves are read
// through.
//
// Both features share one file, so a write sends only the section it is changing and the worker
// merges it into what is on disk. That is what stops the two overwriting each other: they are
// switched on separately, their settings cards write independently, and a write that replaced the
// whole document would take the other feature's settings with it whenever the two overlapped.
//

//
// Prefix of the source tag for the settings tasks.
//
// Each task gets its own source rather than sharing one, because shutting a TaskQueue down cancels
// every task under its source: with a shared tag, two reads in flight at once would cancel each
// other and one would come back with no result.
//
const CONFIG_TASK_SOURCE_PREFIX = "config";

//
// The outputs of the read-config worker task.
//
interface IReadConfigOutputs {
    // The automatic import settings, the database they write to and the pacing of the loop.
    autoImport?: IAutoImportFile;

    // The syncing settings, the database the loop pushes and its pacing.
    sync?: ISyncFile;

    // Whether the syncing settings have ever been written.
    syncSettingsWritten?: boolean;
}

//
// Runs one settings task and returns its outputs, throwing when it fails so the caller surfaces a
// real error rather than silently reading or writing nothing.
//
async function runConfigTask(type: string, data: object): Promise<IReadConfigOutputs> {
    const uuidGenerator = new RandomUuidGenerator();
    const queue = new TaskQueue(uuidGenerator, `${CONFIG_TASK_SOURCE_PREFIX}-${uuidGenerator.generate()}`);
    try {
        // Interactive: the settings card cannot render until this comes back, so it must not sit
        // behind whatever the background loops have already queued.
        const taskId = queue.addTask(type, data, undefined, TaskPriority.Interactive);
        const result = await queue.awaitTask(taskId);
        if (!result || result.status === TaskStatus.Failed) {
            throw new Error(`${type} failed: ${result?.errorMessage ?? "no result"}`);
        }
        return (result.outputs ?? {}) as IReadConfigOutputs;
    }
    finally {
        queue.shutdown();
    }
}

//
// Reads the whole file once, for a caller that wants one of its sections.
//
async function readConfig(): Promise<IReadConfigOutputs> {
    return await runConfigTask("read-config", { configPath: CONFIG_PATH });
}

//
// The config.yaml accessor the mobile automatic import settings functions run on.
//
export const mobileAutoImportConfigFile: IAutoImportConfigFile = {
    //
    // Reads the automatic import section, returning the defaults when the file does not exist yet.
    //
    async read(): Promise<IAutoImportFile> {
        const outputs = await readConfig();
        const autoImport = outputs.autoImport;
        return {
            settings: normaliseAutoImportSettings(autoImport?.settings as IAutoImportSettings | undefined),
            defaultDatabasePath: autoImport?.defaultDatabasePath,
            pauseBetweenRunsMs: resolveAutoImportPauseMs(autoImport?.pauseBetweenRunsMs),
        };
    },

    //
    // Writes the automatic import section, leaving every other section of the file as it is.
    //
    async write(contents: IAutoImportFile): Promise<void> {
        await runConfigTask("write-config", {
            configPath: CONFIG_PATH,
            autoImport: {
                settings: contents.settings,
                defaultDatabasePath: contents.defaultDatabasePath,
                pauseBetweenRunsMs: contents.pauseBetweenRunsMs,
            },
        });
    },
};

//
// The config.yaml accessor the mobile syncing settings functions run on.
//
export const mobileSyncConfigFile: ISyncConfigFile = {
    //
    // Reads the syncing section, reporting whether it has ever been written.
    //
    // That is the section rather than the file: automatic import writing its own section brings the
    // file into being, and reporting the file here would tell a fresh install that its syncing
    // settings had already been chosen, leaving syncing off on a phone whose toggles say it is on.
    //
    async read(): Promise<ISyncFileContents> {
        const outputs = await readConfig();
        const sync = outputs.sync;
        return {
            settings: normaliseSyncSettings(sync?.settings as ISyncSettings | undefined),
            databasePath: sync?.databasePath,
            pauseBetweenRunsMs: resolveSyncPauseMs(sync?.pauseBetweenRunsMs),
            exists: outputs.syncSettingsWritten === true,
        };
    },

    //
    // Writes the syncing section, leaving every other section of the file as it is.
    //
    async write(contents: ISyncFile): Promise<void> {
        await runConfigTask("write-config", {
            configPath: CONFIG_PATH,
            sync: {
                settings: contents.settings,
                databasePath: contents.databasePath,
                pauseBetweenRunsMs: contents.pauseBetweenRunsMs,
            },
        });
    },
};
