import { TaskQueue, TaskStatus, TaskPriority } from "task-queue";
import { RandomUuidGenerator } from "utils";
import { normaliseAutoImportSettings, type IAutoImportSettings } from "api/src/lib/auto-import-settings";
import { resolveAutoImportPauseMs, type IAutoImportFile } from "api/src/lib/auto-import-mobile";
import { AUTO_IMPORT_CONFIG_PATH } from "api/src/lib/mobile-config-paths";
import type { IAutoImportConfigFile } from "./mobile-auto-import-file";

//
// Reads and writes the mobile auto-import.toml.
//
// The same arrangement as mobile-databases-config-file.ts, and for the same reason: the WebView has
// no filesystem access, so the file is reached through the embedded worker's read-auto-import-config
// / write-auto-import-config tasks, which run over the same storage layer the databases themselves
// are read through.
//

//
// Prefix of the source tag for the settings tasks.
//
// Each task gets its own source rather than sharing one, because shutting a TaskQueue down cancels
// every task under its source: with a shared tag, two reads in flight at once would cancel each
// other and one would come back with no result.
//
const AUTO_IMPORT_CONFIG_TASK_SOURCE_PREFIX = "auto-import-config";

//
// The outputs of the read-auto-import-config worker task.
//
interface IReadAutoImportConfigOutputs {
    // The settings, already filled from the defaults by the handler.
    settings?: IAutoImportSettings;

    // The database automatic import writes to, absent when none has been chosen yet.
    defaultDatabasePath?: string;

    // The gap between background import passes, in milliseconds.
    pauseBetweenRunsMs?: number;
}

//
// Runs one settings task and returns its outputs, throwing when it fails so the caller surfaces a
// real error rather than silently reading or writing nothing.
//
async function runAutoImportConfigTask(type: string, data: object): Promise<IReadAutoImportConfigOutputs> {
    const uuidGenerator = new RandomUuidGenerator();
    const queue = new TaskQueue(uuidGenerator, `${AUTO_IMPORT_CONFIG_TASK_SOURCE_PREFIX}-${uuidGenerator.generate()}`);
    try {
        // Interactive: the settings card cannot render until this comes back, so it must not sit
        // behind whatever automatic import has already queued.
        const taskId = queue.addTask(type, data, undefined, TaskPriority.Interactive);
        const result = await queue.awaitTask(taskId);
        if (!result || result.status === TaskStatus.Failed) {
            throw new Error(`${type} failed: ${result?.errorMessage ?? "no result"}`);
        }
        return (result.outputs ?? {}) as IReadAutoImportConfigOutputs;
    }
    finally {
        queue.shutdown();
    }
}

//
// The auto-import.toml accessor the mobile settings functions run on.
//
export const mobileAutoImportConfigFile: IAutoImportConfigFile = {
    //
    // Reads auto-import.toml, returning the defaults when the file does not exist yet.
    //
    async read(): Promise<IAutoImportFile> {
        const outputs = await runAutoImportConfigTask("read-auto-import-config", { configPath: AUTO_IMPORT_CONFIG_PATH });
        return {
            settings: normaliseAutoImportSettings(outputs.settings),
            defaultDatabasePath: outputs.defaultDatabasePath,
            pauseBetweenRunsMs: resolveAutoImportPauseMs(outputs.pauseBetweenRunsMs),
        };
    },

    //
    // Writes auto-import.toml, replacing its contents.
    //
    async write(contents: IAutoImportFile): Promise<void> {
        await runAutoImportConfigTask("write-auto-import-config", {
            configPath: AUTO_IMPORT_CONFIG_PATH,
            settings: contents.settings,
            defaultDatabasePath: contents.defaultDatabasePath,
            pauseBetweenRunsMs: contents.pauseBetweenRunsMs,
        });
    },
};
