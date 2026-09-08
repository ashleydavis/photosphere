import { TaskQueue, TaskStatus, TaskPriority } from "task-queue";
import { RandomUuidGenerator } from "utils";
import { normaliseAutoImportSettings, type IAutoImportSettings } from "api/src/lib/auto-import-settings";
import { resolveAutoImportPauseMs, type IAutoImportFile } from "api/src/lib/auto-import-mobile";
import { INITIAL_SYNC_SETTINGS, normaliseSyncSettings, resolveSyncPauseMs, type ISyncFile, type ISyncSettings } from "api/src/lib/sync-settings";
import type { IAppConfigValue } from "node-api/src/lib/app-config-format";
import type { IAppStateValue } from "node-api/src/lib/app-state-format";
import type { INewsFeedItem, INewsState } from "node-api/src/lib/state-format";

//
// Reads and writes the mobile config.yaml.
//
// The same arrangement as mobile-databases-config-file.ts, and for the same reason: the WebView has
// no filesystem access, so the file is reached through the embedded worker's read-config /
// write-config tasks, which run over the same storage layer the databases themselves are read
// through.
//
// A setting reaches this file exactly the way it reaches the desktop app's: the interface names a key,
// and the store underneath writes it wherever the shared format says it belongs. Nothing here knows
// one key from another. Automatic import and syncing used to have accessors of their own, reached by
// matching the key against a list, which meant the same settings card took three different routes to
// the same file depending on which key it touched, and the desktop app took one.
//
// A write sends only the part it is changing and the worker merges it into what is on disk, so two
// features switched on separately cannot overwrite each other. Every write goes through the one lock
// below, because each is a read and a write as separate round trips and two of them interleaving
// loses one of the changes.
//
// What is left below beside the two stores is what the phone does and the desktop does not: seeding
// the syncing settings a fresh install starts from, recording the database the background sync
// pushes, and reading whole sections for the background work to plan from.
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

    // Every setting that has a value, under the flat name the interface uses for it.
    settings?: Record<string, IAppConfigValue>;
}

//
// The outputs of the read-state worker task.
//
interface IReadStateOutputs {
    // Every key that has a value, under the flat name the interface uses for it.
    settings?: Record<string, IAppStateValue>;

    // What the notification system has already shown, and the feed it has in hand.
    news?: INewsState;
}

//
// Runs one settings task and returns its outputs, throwing when it fails so the caller surfaces a
// real error rather than silently reading or writing nothing.
//
async function runSettingsTask(type: string, data: object): Promise<object> {
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
        return result.outputs ?? {};
    }
    finally {
        queue.shutdown();
    }
}

//
// Runs one config.yaml task and returns its outputs.
//
async function runConfigTask(type: string, data: object): Promise<IReadConfigOutputs> {
    return await runSettingsTask(type, data) as IReadConfigOutputs;
}

//
// Runs one state.yaml task and returns its outputs.
//
async function runStateTask(type: string, data: object): Promise<object> {
    return await runSettingsTask(type, data);
}

//
// Reads the whole file once, for a caller that wants one of its sections.
//
async function readConfig(): Promise<IReadConfigOutputs> {
    return await runConfigTask("read-config", { configPath: "config.yaml" });
}

//
// Tail of the chain that serialises the writes below.
//
// Each write reads the file and writes it back, and each of those is a separate round trip, so two
// issued back to back would both read the same file and the second would drop what the first one
// changed. The same thing happened to the databases list when it moved into a file, where seeding the
// databases and then the recents lost one of the two.
//
let configOperationChain: Promise<void> = Promise.resolve();

//
// Runs one write with no other write in flight.
//
// The chain continues on both settle paths so one failed operation does not wedge every later one.
// The caller still sees its own rejection: only the chain's copy of the outcome is discarded.
//
async function withConfigLock<OperationResult>(operation: () => Promise<OperationResult>): Promise<OperationResult> {
    const runAfterPrevious = configOperationChain.then(operation, operation);
    configOperationChain = runAfterPrevious.then(() => undefined, () => undefined);
    return runAfterPrevious;
}

//
// Reads the whole state file once, for a caller that wants one part of it.
//
async function readState(): Promise<IReadStateOutputs> {
    return await runStateTask("read-state", { statePath: "state.yaml" }) as IReadStateOutputs;
}

//
// Reads and writes one value by the flat name the interface uses for it.
//
// Two of these are exported below, one per file, and the caller picks: the config context is given
// the config.yaml one and the state context the state.yaml one. Nothing works out where a key
// belongs. Both used to be the WebView's own local storage, which nothing outside the WebView can
// read and the operating system can clear.
//
export interface ISettingsFile {
    // Reads one value, or undefined when nothing has been stored under that key.
    get(key: string): Promise<IAppConfigValue | undefined>;

    // Writes one value. undefined removes it.
    set(key: string, value: IAppConfigValue | undefined): Promise<void>;
}

//
// Builds the entry sent for one write.
//
// A cleared value is sent with no value at all, because the task's input crosses to the worker as
// JSON: a property set to undefined disappears on the way, so "clear this key" and "do not touch this
// key" have to differ by more than that.
//
function writeEntry(key: string, value: IAppConfigValue | undefined): object {
    if (value === undefined) {
        return {
            key,
        };
    }
    return {
        key,
        value,
    };
}

//
// The config.yaml accessor: what the user chose.
//
export const mobileConfigSettingsFile: ISettingsFile = {
    // Not serialised with the writes, on purpose: a read changes nothing, so the worst a read beside a
    // write can give is the file as it was a moment before. Queueing them would make the interface's
    // startup reads, which are one per setting and several at once, wait for each other.
    async get(key: string): Promise<IAppConfigValue | undefined> {
        const outputs = await readConfig();
        return outputs.settings ? outputs.settings[key] : undefined;
    },

    async set(key: string, value: IAppConfigValue | undefined): Promise<void> {
        await withConfigLock(async () => {
            await runConfigTask("write-config", {
                configPath: "config.yaml",
                entries: [writeEntry(key, value)],
            });
        });
    },
};

//
// The state.yaml accessor: what the app remembered.
//
export const mobileStateSettingsFile: ISettingsFile = {
    async get(key: string): Promise<IAppConfigValue | undefined> {
        const outputs = await readState();
        return outputs.settings ? outputs.settings[key] : undefined;
    },

    async set(key: string, value: IAppConfigValue | undefined): Promise<void> {
        await withConfigLock(async () => {
            await runStateTask("write-state", {
                statePath: "state.yaml",
                entries: [writeEntry(key, value)],
            });
        });
    },
};

//
// Reads and writes what the notification system has already shown on this install, and the feed it
// has in hand to show from.
//
// The same `news` section of the same state.yaml the CLI and the desktop app record it in, so a news
// item means the same thing to the phone as it does to them.
//
export interface INewsStateFile {
    // Reads the state, returning an empty state when nothing has been shown yet.
    read(): Promise<INewsState>;

    // Records a news item as shown. Already-recorded ids are left as they are.
    addShownNewsId(newsId: string): Promise<void>;

    // Records the release the user has been told about.
    setLastShownUpdateVersion(version: string): Promise<void>;

    // Replaces the feed the app has in hand.
    setFeed(feed: INewsFeedItem[]): Promise<void>;
}

//
// The state.yaml accessor the mobile news state goes through.
//
export const mobileNewsStateFile: INewsStateFile = {
    async read(): Promise<INewsState> {
        const outputs = await readState();
        return outputs.news ?? emptyNewsState();
    },

    async addShownNewsId(newsId: string): Promise<void> {
        await withConfigLock(async () => {
            const news = (await readState()).news ?? emptyNewsState();
            if (news.shownNewsIds.includes(newsId)) {
                return;
            }
            await writeNews({
                ...news,
                shownNewsIds: [...news.shownNewsIds, newsId],
            });
        });
    },

    async setLastShownUpdateVersion(version: string): Promise<void> {
        await withConfigLock(async () => {
            const news = (await readState()).news ?? emptyNewsState();
            await writeNews({
                ...news,
                lastShownUpdateVersion: version,
            });
        });
    },

    async setFeed(feed: INewsFeedItem[]): Promise<void> {
        await withConfigLock(async () => {
            const news = (await readState()).news ?? emptyNewsState();
            await writeNews({
                ...news,
                feed,
            });
        });
    },
};

//
// A news state with nothing shown and nothing in hand.
//
function emptyNewsState(): INewsState {
    return {
        shownNewsIds: [],
        feed: [],
    };
}

//
// Writes the whole news section, leaving every other part of the state file as it is.
//
async function writeNews(news: INewsState): Promise<void> {
    await runStateTask("write-state", {
        statePath: "state.yaml",
        news: {
            shownNewsIds: news.shownNewsIds,
            lastShownUpdateVersion: news.lastShownUpdateVersion,
            feed: news.feed,
        },
    });
}

//
// What the syncing section holds, and whether it has ever been written.
//
// The two are different questions and both are needed: a section nobody has written reads as syncing
// off, which is the right answer for a background loop that would otherwise push over a metered
// connection on a guess, and the wrong one to put in front of a new user whose toggles say on.
//
export interface IMobileSyncSettings {
    // The settings, already filled from the defaults by the reader.
    settings: ISyncSettings;

    // The database the background sync pushes, or undefined when none has been opened yet.
    databasePath: string | undefined;

    // The gap between background sync passes, in milliseconds.
    pauseBetweenRunsMs: number;

    // Whether the syncing settings have ever been written.
    //
    // It is the section rather than the file: automatic import writing its own section brings the
    // file into being, and answering for the file would tell a fresh install that its syncing
    // settings had already been chosen, leaving syncing off on a phone whose toggles say it is on.
    written: boolean;
}

//
// Reads the automatic import section, returning the defaults when nothing has been written yet.
//
// This is not how the settings card reads them: that goes through the ordinary config store, the same
// on every platform. This is for the background work, which needs the whole section at once to decide
// whether to run and what to import into.
//
export async function readMobileAutoImportSettings(): Promise<IAutoImportFile> {
    const autoImport = (await readConfig()).autoImport;
    return {
        settings: normaliseAutoImportSettings(autoImport?.settings as IAutoImportSettings | undefined),
        defaultDatabasePath: autoImport?.defaultDatabasePath,
        pauseBetweenRunsMs: resolveAutoImportPauseMs(autoImport?.pauseBetweenRunsMs),
    };
}

//
// Reads the syncing section, reporting whether it has ever been written. For the background work, for
// the same reason as above.
//
export async function readMobileSyncSettings(): Promise<IMobileSyncSettings> {
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
// What the syncing section should become when a fresh installation is seeded, or undefined to leave
// it exactly as it is.
//
// The background sync loop reads this file, and a section it cannot read means syncing off. That is
// the safe answer for the loop and the wrong one for a new user, whose toggles show syncing on and
// Wi-Fi-only on before they touch anything, so the app writes what the toggles say the first time it
// runs and the loop and the interface agree from then on.
//
// A section that has been written is left alone. Overwriting it would put syncing back on for
// somebody who had switched it off, every time the app started.
//
export function planSyncSeed(current: IMobileSyncSettings): ISyncFile | undefined {
    if (current.written) {
        return undefined;
    }

    return {
        settings: { ...INITIAL_SYNC_SETTINGS },
        databasePath: current.databasePath,
        pauseBetweenRunsMs: resolveSyncPauseMs(current.pauseBetweenRunsMs),
    };
}

//
// What the syncing section should become when a database is opened, or undefined to leave it as it is.
//
// Recording it is what makes background syncing work for the database the user is actually using.
// Without it the loop would have nothing to push until automatic import had been switched on and made
// one, tying together two features that are switched on separately.
//
// The same path again is left alone rather than rewritten: a database is opened on every launch and
// on every switch between databases, and there is no reason to rewrite a file to say what it already
// says.
//
export function planSyncDatabase(current: IMobileSyncSettings, databasePath: string): ISyncFile | undefined {
    if (current.databasePath === databasePath) {
        return undefined;
    }

    return {
        settings: current.written
            ? normaliseSyncSettings(current.settings)
            : { ...INITIAL_SYNC_SETTINGS },
        databasePath,
        pauseBetweenRunsMs: resolveSyncPauseMs(current.pauseBetweenRunsMs),
    };
}

//
// Writes the settings a fresh installation starts from, unless they have been written already.
//
export async function seedMobileSyncSettings(): Promise<void> {
    await withConfigLock(async () => {
        const planned = planSyncSeed(await readMobileSyncSettings());
        if (planned) {
            await writeSyncSection(planned);
        }
    });
}

//
// Records the database the background sync pushes, when it is not the one already recorded.
//
export async function recordMobileSyncDatabase(databasePath: string): Promise<void> {
    await withConfigLock(async () => {
        const planned = planSyncDatabase(await readMobileSyncSettings(), databasePath);
        if (planned) {
            await writeSyncSection(planned);
        }
    });
}

//
// Writes the whole syncing section, leaving every other section of the file as it is.
//
// The section rather than a key at a time, because the database path and the pacing are not settings
// the interface names and have no key to be written under.
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
