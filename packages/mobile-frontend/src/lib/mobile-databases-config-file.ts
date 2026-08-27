import { TaskQueue, TaskStatus, TaskPriority } from "task-queue";
import { RandomUuidGenerator } from "utils";
import type { IDatabaseEntry } from "user-interface";
import { DATABASES_CONFIG_PATH } from "api/src/lib/mobile-config-paths";
import type { IDatabasesConfig, IDatabasesConfigFile } from "./mobile-config-store";

//
// Reads and writes the mobile databases.toml.
//
// This is the mobile counterpart of desktop reading and writing the file with node's fs in
// packages/node-api/src/lib/databases-config.ts. The WebView has no filesystem access, so the file
// is reached through the embedded worker's read-databases-config / write-databases-config tasks,
// which run over the same storage layer the databases themselves are read through.
//

//
// Sandbox-relative path of databases.toml. Re-exported so the callers here keep reaching it by the
// name they always have; it is defined in api/src/lib/mobile-config-paths.ts because the worker
// opens the same file for the background import and cannot reach this package.
//
export { DATABASES_CONFIG_PATH } from "api/src/lib/mobile-config-paths";

//
// Prefix of the source tag for the config tasks.
//
// Each task gets its own source rather than sharing one, because shutting a TaskQueue down cancels
// every task under its source: with a shared tag, two config reads in flight at once (the sidebar's
// recents and the database list, say) cancelled each other and one came back with no result.
//
const CONFIG_TASK_SOURCE_PREFIX = "databases-config";

//
// The outputs of the read-databases-config worker task.
//
interface IReadDatabasesConfigOutputs {
    // The configured databases.
    databases?: IDatabaseEntry[];

    // Recently opened database names, most recent first.
    recentDatabaseNames?: string[];

    // Path of the database to open again on the next start, absent when the file names none.
    lastDatabase?: string;
}

//
// Runs one config task and returns its outputs, throwing when it fails so the caller surfaces a real
// error rather than silently reading or writing nothing.
//
async function runConfigTask(type: string, data: object): Promise<IReadDatabasesConfigOutputs> {
    const uuidGenerator = new RandomUuidGenerator();
    const queue = new TaskQueue(uuidGenerator, `${CONFIG_TASK_SOURCE_PREFIX}-${uuidGenerator.generate()}`);
    try {
        // Interactive: nothing in the app can be listed or opened until this comes back, so it must
        // not sit behind whatever automatic import has already queued.
        const taskId = queue.addTask(type, data, undefined, TaskPriority.Interactive);
        const result = await queue.awaitTask(taskId);
        if (!result || result.status === TaskStatus.Failed) {
            throw new Error(`${type} failed: ${result?.errorMessage ?? "no result"}`);
        }
        return (result.outputs ?? {}) as IReadDatabasesConfigOutputs;
    }
    finally {
        queue.shutdown();
    }
}

//
// The databases.toml accessor the mobile config store runs on.
//
export const mobileDatabasesConfigFile: IDatabasesConfigFile = {
    //
    // Reads databases.toml, returning empty lists when the file does not exist yet.
    //
    async read(): Promise<IDatabasesConfig> {
        const outputs = await runConfigTask("read-databases-config", { configPath: DATABASES_CONFIG_PATH });
        return {
            databases: outputs.databases ?? [],
            recentDatabaseNames: outputs.recentDatabaseNames ?? [],
            lastDatabase: outputs.lastDatabase,
        };
    },

    //
    // Writes databases.toml, replacing its contents.
    //
    async write(config: IDatabasesConfig): Promise<void> {
        await runConfigTask("write-databases-config", {
            configPath: DATABASES_CONFIG_PATH,
            databases: config.databases,
            recentDatabaseNames: config.recentDatabaseNames,
            lastDatabase: config.lastDatabase,
        });
    },
};
