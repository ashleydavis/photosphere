import { TaskQueue, TaskStatus, TaskPriority } from "task-queue";
import { RandomUuidGenerator } from "utils";
import { normaliseAutoImportSettings, type IAutoImportSettings } from "api/src/lib/auto-import-settings";
import { resolveAutoImportPauseMs, type IAutoImportFile } from "api/src/lib/auto-import-mobile";
import { normaliseSyncSettings, resolveSyncPauseMs, type ISyncFile, type ISyncSettings } from "api/src/lib/sync-settings";
import { planSyncDatabase, planSyncSeed, type IMobileSyncSettings } from "./background-work";

//
// The settings a phone's background work plans from, read and written through the core's read-config and write-config tasks.
//
// The page reaches a single setting through the core's get-config and set-config channels. The background work needs whole sections at
// once (the automatic import settings with the database they write to, the syncing settings with the database the loop pushes), and
// writes the syncing section as a whole, so it asks for them through the tasks that read and write the config file.
//

//
// Prefix of the source tag for the settings tasks. Each task gets its own source rather than sharing one, because shutting a TaskQueue
// down cancels every task under its source: with a shared tag, two reads in flight at once would cancel each other.
//
const CONFIG_TASK_SOURCE_PREFIX = "config";

//
// The outputs of the read-config task.
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
// Runs one config task and returns its outputs, throwing when it fails so the caller surfaces a real error rather than silently
// reading or writing nothing.
//
async function runConfigTask(type: string, data: object): Promise<IReadConfigOutputs> {
    const uuidGenerator = new RandomUuidGenerator();
    const queue = new TaskQueue(uuidGenerator, `${CONFIG_TASK_SOURCE_PREFIX}-${uuidGenerator.generate()}`);
    try {
        // Interactive: the settings card cannot render until this comes back, so it must not sit behind whatever the background loops
        // have already queued.
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
    return await runConfigTask("read-config", {
        configPath: "config.yaml",
    });
}

//
// Tail of the chain that serialises the writes below. Each write reads the file and writes it back as separate round trips, so two
// issued back to back would both read the same file and the second would drop what the first one changed.
//
let configOperationChain: Promise<void> = Promise.resolve();

//
// Runs one read-modify-write with no other such operation in flight. The chain continues on both settle paths so one failed operation
// does not wedge every later one; the caller still sees its own rejection.
//
async function withConfigLock<OperationResult>(operation: () => Promise<OperationResult>): Promise<OperationResult> {
    const runAfterPrevious = configOperationChain.then(operation, operation);
    configOperationChain = runAfterPrevious.then(() => undefined, () => undefined);
    return runAfterPrevious;
}

//
// Reads the automatic import section, returning the defaults when nothing has been written yet.
//
export async function readAutoImportSettings(): Promise<IAutoImportFile> {
    const autoImport = (await readConfig()).autoImport;
    return {
        settings: normaliseAutoImportSettings(autoImport?.settings as IAutoImportSettings | undefined),
        defaultDatabasePath: autoImport?.defaultDatabasePath,
        pauseBetweenRunsMs: resolveAutoImportPauseMs(autoImport?.pauseBetweenRunsMs),
    };
}

//
// Reads the syncing section, reporting whether it has ever been written.
//
export async function readSyncSettings(): Promise<IMobileSyncSettings> {
    const outputs = await readConfig();
    const sync = outputs.sync;
    return {
        settings: normaliseSyncSettings(sync?.settings as ISyncSettings | undefined),
        databasePath: sync?.databasePath,
        pauseBetweenRunsMs: resolveSyncPauseMs(sync?.pauseBetweenRunsMs),
        written: outputs.syncSettingsWritten === true,
    };
}

//
// Writes the whole syncing section, leaving every other section of the file as it is.
//
async function writeSyncSection(contents: ISyncFile): Promise<void> {
    await runConfigTask("write-config", {
        configPath: "config.yaml",
        sync: {
            settings: contents.settings,
            databasePath: contents.databasePath,
            pauseBetweenRunsMs: contents.pauseBetweenRunsMs,
        },
    });
}

//
// Writes the syncing settings a fresh installation starts from, unless they have been written already.
//
export async function seedSyncSettings(): Promise<void> {
    await withConfigLock(async () => {
        const planned = planSyncSeed(await readSyncSettings());
        if (planned) {
            await writeSyncSection(planned);
        }
    });
}

//
// Records the database the background sync pushes, when it is not the one already recorded.
//
export async function recordSyncDatabase(databasePath: string): Promise<void> {
    await withConfigLock(async () => {
        const planned = planSyncDatabase(await readSyncSettings(), databasePath);
        if (planned) {
            await writeSyncSection(planned);
        }
    });
}
