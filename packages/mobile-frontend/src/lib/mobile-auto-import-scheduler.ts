import { IAutoImportSettings, IDeviceAlbumAutoImportSource } from "api/src/lib/auto-import-settings";
import { AutoImportQueue, IBackfillCursor } from "api/src/lib/auto-import-queue";
import {
    IAutoImportItemMessage,
    IAutoImportProgressMessage,
    IAutoImportResult,
    runAutoImportLoop,
} from "api/src/lib/auto-import-loop";
import { IImportAssetsResult } from "api/src/lib/import-assets.types";
import { IDeviceMediaLibrary } from "./device-media-library";
import { DeviceMediaSource } from "./device-media-source";

//
// Runs automatic import on mobile, from the WebView.
//
// The loop itself is `runAutoImportLoop`, the same one the CLI and the desktop run from the
// auto-import task. Mobile cannot run it from a task: the embedded engine pool has three slots, the
// asset server holds one for the life of the app, and a long-running orchestrator in a second slot
// leaves nothing for the tasks the import it queues needs in turn, so the import waits for a slot
// that can never come free. Driven from here it occupies no slot at all, and the import it queues
// behaves exactly as a manual import does.
//
// Everything the loop needs that a WebView cannot do is passed in: running the import, reading the
// database's content hashes, and recording where the backfill has reached.
//

//
// Source tag the import tasks this scheduler queues are grouped under, so they can be cancelled
// together when automatic import is switched off.
//
export const AUTO_IMPORT_TASK_SOURCE = "auto-import";

//
// Everything the scheduler needs from the app around it.
//
export interface IMobileAutoImportSchedulerDeps {
    // Where the device photo library is read from.
    library: IDeviceMediaLibrary;

    // The database being imported into, named on every arrival so the gallery can tell an arrival in
    // the database it is showing from one in another.
    databasePath: string;

    // Runs one import of the given sandbox paths, returning what it did, or undefined when the
    // import could not be started at all.
    importBatch: (paths: string[]) => Promise<IImportAssetsResult | undefined>;

    // Every content hash the local database holds an original for, lower-case hex.
    loadDatabaseHashes: () => Promise<Set<string>>;

    // Records where the backfill has reached, so a restart resumes rather than rescanning.
    persistCursor: (cursor: IBackfillCursor) => Promise<void>;

    // Reports progress, so the interface can show what is happening.
    onProgress: (message: IAutoImportProgressMessage) => void;

    // Reports one arrival, so the gallery can show it landing.
    onItem: (message: IAutoImportItemMessage) => void;

    // Says something worth reading in the log.
    logInfo: (message: string) => void;

    // Says something that went wrong and was not thrown, so it is not lost.
    logError: (message: string) => void;
}

//
// Drives automatic import on mobile until it is stopped.
//
export class MobileAutoImportScheduler {
    // Everything the scheduler needs from the app around it.
    private readonly deps: IMobileAutoImportSchedulerDeps;

    // True once stop() has been called, which is what ends the loop.
    private stopped = false;

    // The run in progress, so stop() can wait for it to unwind rather than leaving it going.
    private running: Promise<IAutoImportResult> | undefined = undefined;

    constructor(deps: IMobileAutoImportSchedulerDeps) {
        this.deps = deps;
    }

    //
    // True while a run is in progress.
    //
    isRunning(): boolean {
        return this.running !== undefined;
    }

    //
    // Starts automatic import, and returns once it has stopped.
    //
    // Throws if a run is already in progress, rather than starting a second one over the top: two
    // loops walking the same library would import everything twice and race over the same cursor.
    //
    start(settings: IAutoImportSettings, startCursor: IBackfillCursor): Promise<IAutoImportResult> {
        if (this.running !== undefined) {
            throw new Error("Automatic import is already running. Stop it before starting it again.");
        }

        this.stopped = false;

        const deviceSources = settings.sources.filter(source => source.type === "device-album") as IDeviceAlbumAutoImportSource[];
        if (deviceSources.length === 0) {
            throw new Error("Automatic import was started with no device album sources configured. Nothing would be imported.");
        }

        const source = new DeviceMediaSource(deviceSources, settings.pollIntervalMs, this.deps.library);
        const queue = new AutoImportQueue(settings.backfillItemsPerMinute, startCursor);

        this.running = runAutoImportLoop({
            source,
            queue,
            databasePath: this.deps.databasePath,
            cleanupEnabled: settings.cleanupEnabled,
            once: false,
            isCancelled: () => this.stopped,
            nowMs: () => Date.now(),
            sleep: (milliseconds: number) => new Promise<void>(resolve => setTimeout(resolve, milliseconds)),
            importBatch: this.deps.importBatch,
            loadDatabaseHashes: this.deps.loadDatabaseHashes,
            persistCursor: this.deps.persistCursor,
            onProgress: this.deps.onProgress,
            onItem: this.deps.onItem,
            logInfo: this.deps.logInfo,
            logError: this.deps.logError,
        });

        return this.running.finally(() => {
            this.running = undefined;
        });
    }

    //
    // Stops automatic import and waits for the run to unwind.
    //
    // Waiting matters: the settings can be switched off and straight back on, and starting a second
    // loop while the first is still mid-batch would import everything twice.
    //
    async stop(): Promise<void> {
        this.stopped = true;

        const running = this.running;
        if (running === undefined) {
            return;
        }

        try {
            await running;
        }
        catch (error) {
            // The failure was already reported to whoever started the run. Rethrowing it here would
            // make switching the setting off look like it failed, when what failed was the run.
            this.deps.logError(`Automatic import ended with an error: ${(error as Error).message}`);
        }
    }
}
