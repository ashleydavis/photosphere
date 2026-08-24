import React, { ReactNode, createContext, useContext, useEffect, useRef, useState } from "react";
import { IGalleryItem } from "../lib/gallery-item";
import { GallerySourceContext, IItemsUpdate, IGalleryItemMap, IGallerySource } from "./gallery-source";
import { IAsset, IDatabaseOp } from "api";
import type { ISaveAssetItem } from "api";
import type { IMoveAssetsData } from "node-api";
import { log, retry } from "utils";
import { IObservable, Observable } from "../lib/subscription";
import { loadAssets as loadAssetsApi } from "api/src/lib/load-assets";
import type { ILoadAssetsData, ILoadAssetsResult } from "api/src/lib/load-assets.types";
import type { ISyncBatchMessage } from "api/src/lib/sync-database.types";
import { TaskStatus, TaskQueue, TaskPriority, getQueueBackend } from "task-queue";
import type { IQueueBackend } from "task-queue";
import { usePlatform } from "./platform-context";
import { useApi } from "./api-context";
import type { IDownloadAssetItem } from "./platform-context";
import { useToast } from "./toast-context";
import { useUuidGenerator } from "./uuid-generator-context";
import { useConfig } from "./config-context";
import { markRecentArrival } from "../lib/recent-arrivals";

//
// How many times an asset request is attempted, and how long apart.
//
// Three, a quarter of a second apart, because the failure this exists for is a single request to a
// live loopback port getting no reply at all. Something that fails three times over half a second is
// not that, and is reported rather than waited on.
//
const ASSET_REQUEST_ATTEMPTS = 3;
const ASSET_RETRY_DELAY_MS = 250;

//
// Adds "asset database" specific functionality to the gallery source.
//
export interface IAssetDatabase extends IGallerySource {
    //
    // The currently viewed database path.
    //
    databasePath: string | undefined;

    //
    // Sets the viewed database.
    //
    setDatabasePath(databasePath: string): void;

    //
    // Closes the current database.
    //
    closeDatabase(): Promise<void>;

    //
    // Moves assets to another database.
    //
    moveToDatabase(assetIds: string[], databasePath: string): Promise<void>;

    //
    // Opens a database file dialog (Electron only).
    //
    selectAndOpenDatabase(): Promise<void>;

    //
    // Shows a directory picker, creates a new database at the chosen path, and loads it.
    // Returns without opening anything if the user cancels the picker.
    //
    createDatabase(): Promise<void>;

    //
    // Creates a new database at the given path (no folder picker) and loads it.
    //
    createDatabaseAtPath(dbPath: string): Promise<void>;

    //
    // Opens a database by path directly (without showing file dialog).
    //
    openDatabase(dbPath: string): Promise<void>;

    //
    // True while a background sync with the origin database is in progress.
    //
    isSyncing: boolean;

    //
    // Returns a direct URL for an asset, suitable for use in img src attributes.
    //
    assetUrl(assetId: string, assetType: string): string;

    //
    // Downloads a single asset by showing the platform save picker, queueing a save-asset
    // task, and surfacing a success or failure toast when the task completes.
    //
    downloadAsset(asset: IGalleryItem): Promise<void>;

    //
    // Downloads multiple assets to a single folder by showing the folder picker,
    // queueing a save-assets-batch task, and surfacing success/partial/failure toasts when it completes.
    //
    downloadAssets(assets: IDownloadAssetItem[]): Promise<void>;
}

export interface IAssetDatabaseProviderProps {
    children: ReactNode | ReactNode[];
    queueBackend: IQueueBackend;
    restApiUrl: string;
}

//
// Shape of the check-database-exists task result payload. Declared locally because user-interface does
// not depend on node-api's worker types; the result is read structurally.
//
interface ICheckDatabaseExistsOutputs {
    // True when a real database is accessible at the probed path.
    exists: boolean;
}

export function AssetDatabaseProvider({ children, queueBackend, restApiUrl }: IAssetDatabaseProviderProps) {
    const platform = usePlatform();
    const config = useConfig();
    const api = useApi();
    const uuidGenerator = useUuidGenerator();
    const { addToast } = useToast();

    //
    // Set to true while loading assets.
    //
    const [ isLoading, setIsLoading ] = useState(false);

    //
    // Set to true while a background sync with the origin database is in progress.
    //
    const [ isSyncing, setIsSyncing ] = useState(false);

    //
    // The database path currently being loaded (if any).
    //
    const loadingDatabasePath = useRef<string | undefined>(undefined);

    //
    // Unsubscribe function for the current load's task queue callbacks.
    //
    const unsubscribeCurrentLoad = useRef<(() => void) | undefined>(undefined);

    //
    // The TaskQueue instance for the current in-progress load, used to cancel it.
    //
    const currentLoadQueue = useRef<TaskQueue | undefined>(undefined);

    //
    // Set to true while working on something.
    //
    const [ isWorking, setIsWorking ] = useState(false);

    //
    // Assets that have been loaded.
    //
    const loadedAssets = useRef<IGalleryItemMap>({});

    //
    // The database path currently being used.
    //
    const [ databasePath, setDatabasePath ] = useState<string | undefined>(undefined);

    //
    // Assets that have been loaded.
    //
    function getAssets(): IGalleryItemMap {
        return loadedAssets.current;
    }

    //
    // Subscribes to resets of the gallery.
    //
    const onReset = useRef<IObservable<void>>(new Observable<void>());

    //
    // Subscribes to new gallery items.
    //
    const onNewItems = useRef<IObservable<IGalleryItem[]>>(new Observable<IGalleryItem[]>());

    //
    // Persists metadata operations via the local REST API (same process as GET /asset in Electron).
    //
    async function persistDatabaseOps(ops: IDatabaseOp[]): Promise<void> {
        if (ops.length === 0) {
            return;
        }

        await api.post(`${restApiUrl}/apply-database-ops`, { ops }, {
            headers: { "Content-Type": "application/json" },
        });

        // Logged because until now the success of a metadata write was observable nowhere at all.
        // Every caller reaches this through a debounce with nothing awaiting the promise, and the app
        // installs no unhandledrejection handler, so a write that failed left the app looking exactly
        // like one that succeeded: the edit sits in React state either way. This is the same kind of
        // lifecycle line as "Database opened" and "Sync completed", and it is what says the record is
        // on disk rather than only on screen.
        log.info(`Database ops applied: ${ops.length} op(s)`);

        platform.notifyDatabaseEdited();
    }

    //
    // Invokes subscriptions for new assets.
    //
    function _onNewItems(assets: IAsset[]) {
        for (const asset of assets) {
            loadedAssets.current[asset._id] = asset;
        }               

        onNewItems.current.invoke(assets);
    }

    const onItemsUpdated = useRef<IObservable<IItemsUpdate>>(new Observable<IItemsUpdate>());

    //
    // Subscribes to gallery item deletions.
    //
    const onItemsDeleted = useRef<IObservable<IItemsUpdate>>(new Observable<IItemsUpdate>());

    //
    // Updates an existing asset.
    //
    async function updateAsset(assetId: string, partialAsset: Partial<IGalleryItem>): Promise<void> {

        if (!databasePath) {
            throw new Error("No database path provided.");
        }

        const updatedAsset = { ...loadedAssets.current[assetId], ...partialAsset };
        loadedAssets.current[assetId] = updatedAsset;

        onItemsUpdated.current.invoke({ assetIds: [ assetId ] });

        const ops: IDatabaseOp[] = [{
            collectionName: "metadata",
            recordId: assetId,
            databaseId: databasePath,
            op: {
                type: "set",
                fields: partialAsset,
            },
        }];

        await persistDatabaseOps(ops);
    }

    //
    // Update multiple assets with persisted database changes.
    //
    async function updateAssets(assetUpdates: { assetId: string, partialAsset: Partial<IGalleryItem>}[]): Promise<void> {

        if (!databasePath) {
            throw new Error("No database path provided.");
        }

        for (const { assetId, partialAsset } of assetUpdates) {
            loadedAssets.current[assetId] = {
                ...loadedAssets.current[assetId],
                ...partialAsset,
            };
        }

        onItemsUpdated.current.invoke({ assetIds: assetUpdates.map(({ assetId }) => assetId) });

        const ops: IDatabaseOp[] = assetUpdates.map(({ assetId, partialAsset }) => ({
            collectionName: "metadata",
            recordId: assetId,
            databaseId: databasePath,
            op: {
                type: "set",
                fields: partialAsset,
            },
        }));

        await persistDatabaseOps(ops);
    }

    //
    // Adds an array value to the asset.
    //
    async function addArrayValue(assetId: string, field: string, value: any): Promise<void> {

        if (!databasePath) {
            throw new Error("No database path provided.");
        }

        const updatedAsset: any = { ...loadedAssets.current[assetId] };
        if (updatedAsset[field] === undefined || !Array.isArray(updatedAsset[field])) {
            updatedAsset[field] = [];
        }
        updatedAsset[field] = (updatedAsset[field] as any[]).filter(item => item !== value)
        updatedAsset[field].push(value);

        loadedAssets.current[assetId] = updatedAsset;

        onItemsUpdated.current.invoke({ assetIds: [ assetId ] });

        const ops: IDatabaseOp[] = [{
            collectionName: "metadata",
            recordId: assetId,
            databaseId: databasePath,
            op: {
                type: "push",
                field: field,
                value,
            },
        }];

        await persistDatabaseOps(ops);
    }

    //
    // Removes an array value from the asset.
    //
    async function removeArrayValue(assetId: string, field: string, value: any): Promise<void> {

        if (!databasePath) {
            throw new Error("No database path provided.");
        }

        const updatedAsset: any = { ...loadedAssets.current[assetId] };
        if (updatedAsset[field] === undefined) {
            updatedAsset[field] = [];
        }
        updatedAsset[field] = (updatedAsset[field] as any[]).filter(item => item !== value)

        loadedAssets.current[assetId] = updatedAsset;

        onItemsUpdated.current.invoke({ assetIds: [ assetId ] });

        const ops: IDatabaseOp[] = [{
            collectionName: "metadata",
            recordId: assetId,
            databaseId: databasePath,
            op: {
                type: "pull",
                field: field,
                value,
            },
        }];

        await persistDatabaseOps(ops);
    }

    //
    // Deletes the assets.
    //
    async function deleteAssets(assetIds: string[]): Promise<void> {
        await updateAssets(assetIds.map(assetId => ({
            assetId, 
            partialAsset: { deleted: true } 
        })));

        onItemsDeleted.current.invoke({ assetIds });
    }

    //
    // Opens a database file dialog.
    //
    async function selectAndOpenDatabase(): Promise<void> {
        // Call platform.openDatabase which will trigger the platform to show the dialog
        // and send a 'database-opened' event when a file is selected. On mobile, openDatabase
        // is currently a no-op (there is no native database picker yet), so this path opens
        // a database on desktop only.
        await platform.openDatabase();

        // The database-opened event will be handled by the useEffect listener
    }

    //
    // Creates a new database at the given path by queueing a create-database task,
    // awaiting its completion, and then notifying the platform that the database is
    // open (which fires the database-opened callback chain to load the new database).
    //
    async function createDatabaseAtPath(dbPath: string): Promise<void> {
        const queue = new TaskQueue(uuidGenerator, dbPath);
        try {
            // Interactive: the user tapped to open this database and is waiting on the empty gallery.
            const taskId = queue.addTask("create-database", { databasePath: dbPath }, undefined, TaskPriority.Interactive);
            const result = await queue.awaitTask(taskId);
            if (!result || result.status !== TaskStatus.Succeeded) {
                throw new Error(`create-database task did not succeed: ${result?.errorMessage ?? "unknown error"}`);
            }
        }
        finally {
            queue.shutdown();
        }
        await platform.notifyDatabaseOpened(dbPath);
    }

    //
    // Shows a directory picker, creates a new database at the chosen path, and loads it.
    // Returns without opening anything if the user cancels the picker.
    //
    async function createDatabase(): Promise<void> {
        const dbPath = await platform.pickFolder({
            title: "Create Database",
            createDirectory: true,
        });
        if (!dbPath) {
            return;
        }
        await createDatabaseAtPath(dbPath);
    }

    //
    // Whether an accessible database lives at the given path. Runs the check as a worker task (the same
    // check-database-exists handler registered on desktop and mobile) rather than a per-platform call, so
    // "exists" means the same thing everywhere: checkDatabaseExists reports a directory that holds no
    // database as absent.
    //
    // The source is namespaced per database rather than being dbPath itself. This queue shuts down as
    // soon as it has its answer, and shutdown() cancels its whole source, so tagging it dbPath would
    // cancel every other task running against that database: openDatabase calls this first, which is
    // enough to kill a replication of the same database that is already under way. dbPath is shared by
    // load-assets, create-database, move-assets, import, verify and check, so nothing that cancels on
    // completion may use it.
    //
    // The id is generated per call rather than being stable per database, for the same reason
    // read-databases-config generates one. Two checks of the same database can overlap, and with a
    // stable tag they shared a source: the first to finish ran shutdown(), which cancelled the
    // source, which cancelled the second one's task while it was still running. awaitTask resolves
    // undefined for a cancelled task, that became "check-database-exists task did not succeed:
    // unknown error", and openDatabase reported it to the user as "Could not reach the database" for
    // a database that was reachable all along. Desktop test 26 failed that way on two of three CI
    // runs, once on macOS and once on Windows.
    //
    async function checkDatabaseExists(dbPath: string): Promise<boolean> {
        const queue = new TaskQueue(uuidGenerator, `check-database-exists-${uuidGenerator.generate()}`);
        try {
            // Interactive: this runs in front of opening a database, with the user waiting on it.
            const taskId = queue.addTask("check-database-exists", { databasePath: dbPath }, undefined, TaskPriority.Interactive);
            const result = await queue.awaitTask(taskId);
            if (!result || result.status !== TaskStatus.Succeeded) {
                throw new Error(`check-database-exists task did not succeed: ${result?.errorMessage ?? "unknown error"}`);
            }
            const outputs = result.outputs as ICheckDatabaseExistsOutputs | undefined;
            return outputs?.exists === true;
        }
        finally {
            queue.shutdown();
        }
    }

    //
    // Opens a database by path directly (without showing file dialog).
    // Checks accessibility first; if not found, notifies the user and returns without
    // changing state so the previously open database stays loaded.
    //
    async function openDatabase(dbPath: string): Promise<void> {
        // A database that cannot be reached is a different problem from one that is not there, and
        // saying "not found" for an unreachable bucket tells the user their photos are gone when they
        // are merely out of reach. checkDatabaseExists throws for anything that stopped it getting an
        // answer, and only reports false when the storage answered and held no database.
        let exists: boolean;
        try {
            exists = await checkDatabaseExists(dbPath);
        }
        catch (err) {
            log.exception(`Could not reach the database at ${dbPath}`, err as Error);
            addToast({
                message: `Could not reach the database: ${dbPath}`,
                color: 'danger',
                duration: 8000,
            });
            return;
        }

        if (!exists) {
            addToast({
                message: `Database not found: ${dbPath}`,
                color: 'warning',
            });
            return;
        }

        // Reopening the database already open leaves a load that is already running for it alone.
        // closeDatabase cancels that load, and putting the same path straight back does not change
        // databasePath, so what happens next is decided by whether React has flushed the render for
        // the undefined it was set to in between. Neither outcome is right. If it has not, the effect
        // that loads on a path change never re-runs and nothing replaces the load that was just
        // cancelled, so the gallery waits for ever. If it has, a replacement load starts, and then the
        // cancelled load's completion arrives: the completion callback tells loads apart by database
        // path alone, so it takes that one for the replacement's, unsubscribes, and the replacement
        // finishes with nobody listening, leaving the gallery empty.
        //
        // The app restores its last database at startup and starts loading it, so opening that same
        // database from the list a moment later is exactly this case, and it is why desktop smoke test
        // 26 fails both ways. A database whose load has already finished is still closed and reopened
        // as before, because that reload is what several smoke tests wait to see.
        const loadAlreadyRunningForThisDatabase = databasePath === dbPath && loadingDatabasePath.current === dbPath;

        if (databasePath && !loadAlreadyRunningForThisDatabase) {
            await closeDatabase();
        }

        setDatabasePath(dbPath);

        // Remembered here, in the one place every platform opens a database through, so the app
        // reopens it next time it starts. main.tsx reads this key on mount.
        //
        // It used to be written by the Electron main process instead, which is why it only ever
        // worked on the desktop: nothing obliged a new platform to write it and nothing noticed when
        // it did not, so the read simply returned nothing and the app started with nothing open.
        await config.set('lastDatabase', dbPath);

        await platform.notifyDatabaseOpened(dbPath);
    }
    
    //
    // Closes the current database.
    //
    async function closeDatabase(): Promise<void> {
        if (databasePath) {
            cancelDatabaseLoad(databasePath);
        }

        setIsLoading(false);
        setIsSyncing(false);
        loadingDatabasePath.current = undefined;
        setDatabasePath(undefined);
        loadedAssets.current = {};
        onReset.current.invoke();

        // Forgotten, so a database the user closed is not reopened for them on the next start.
        await config.clear('lastDatabase');

        await platform.notifyDatabaseClosed();
    }
   
    //
    // Moves assets to another database using a background task that operates
    // directly on storage -- no REST API involved. Hard-deletes from the source.
    //
    async function moveToDatabase(assetIds: string[], destDatabasePath: string): Promise<void> {
        try {
            setIsWorking(true);

            const queue = new TaskQueue(uuidGenerator, databasePath!);
            const taskId = queue.addTask("move-assets", { sourceDatabasePath: databasePath!, destDatabasePath, assetIds } satisfies IMoveAssetsData);
            const result = await queue.awaitTask(taskId);
            queue.shutdown();

            if (!result || result.status !== TaskStatus.Succeeded) {
                throw new Error(`Move-assets task did not succeed: ${result?.errorMessage ?? "unknown error"}`);
            }

            onItemsDeleted.current.invoke({ assetIds });

            log.event(`Move to database completed: ${assetIds.length} asset${assetIds.length === 1 ? '' : 's'} moved`);
        }
        finally {
            setIsWorking(false);
        }
    }

    //
    // Downloads a single asset by showing the platform save picker, queueing a save-asset
    // task on the local task queue, and surfacing a success or failure toast when the task completes.
    // On Electron destPath is an absolute file path and the success toast offers an "Open Folder" action.
    // On web destPath is just the suggested filename (the browser handles where the bytes land) and no action is offered.
    //
    async function downloadAsset(asset: IGalleryItem): Promise<void> {
        const filename = asset.origFileName || asset._id;
        const result = await platform.saveDownloadedFiles([{ assetId: asset._id, assetType: "asset", filename }], databasePath!);
        if (result.outcome === "cancelled") {
            // Logged for the same reason the completed path below is: cancelling is an outcome the
            // user chose, and until this line existed it was the only outcome of a download that left
            // no trace at all. That silence is what made the export-cancel smoke test unable to tell
            // a cancel that worked from a button that did nothing.
            log.event(`Download cancelled: ${filename}`);
            return;
        }

        if (result.outcome === "failed") {
            addToast({
                message: `Failed to download "${filename}": ${result.errorMessage ?? "unknown error"}`,
                color: "danger",
                duration: 8000,
            });
            return;
        }

        log.event(`Download completed: ${filename}`);
        addToast({
            message: `Downloaded "${filename}"`,
            color: "success",
            action: result.savedFolder
                ? { label: "Open Folder", onClick: () => platform.openFolder(result.savedFolder!) }
                : undefined,
        });
    }

    //
    // Downloads multiple assets to a single folder by showing the folder picker,
    // queueing a save-assets-batch task, and surfacing success/partial/failure toasts when it completes.
    //
    async function downloadAssets(assets: IDownloadAssetItem[]): Promise<void> {
        const saveItems: ISaveAssetItem[] = assets.map(asset => ({
            assetId: asset.assetId,
            assetType: asset.assetType,
            filename: asset.filename,
        }));

        const result = await platform.saveDownloadedFiles(saveItems, databasePath!);
        if (result.outcome === "cancelled") {
            return;
        }

        if (result.outcome === "failed") {
            addToast({
                message: `Failed to download assets: ${result.errorMessage ?? "unknown error"}`,
                color: 'danger',
                duration: 8000,
            });
            return;
        }

        const total = result.savedCount + result.failedCount;
        log.event(`Download to folder completed: ${result.savedCount} assets downloaded`);
        if (result.failedCount === 0) {
            addToast({
                message: `Downloaded ${total} asset${total !== 1 ? 's' : ''}`,
                color: 'success',
                action: result.savedFolder
                    ? { label: 'Open Folder', onClick: () => platform.openFolder(result.savedFolder!) }
                    : undefined,
            });
        }
        else if (result.savedCount === 0) {
            addToast({
                message: `Failed to download ${result.failedCount} asset${result.failedCount !== 1 ? 's' : ''}`,
                color: 'danger',
                duration: 8000,
            });
        }
        else {
            addToast({
                message: `Downloaded ${result.savedCount} of ${total} assets (${result.failedCount} failed)`,
                color: 'warning',
                duration: 8000,
                action: result.savedFolder
                    ? { label: 'Open Folder', onClick: () => platform.openFolder(result.savedFolder!) }
                    : undefined,
            });
        }
    }

    //
    // Loads data for an asset from the current database via the local REST API.
    //
    async function loadAsset(assetId: string, assetType: string): Promise<Blob | undefined> {
        if (!databasePath) {
            throw new Error("No database path provided.");
        }

        // Tried again when it fails. The asset server is on loopback and up long before any of this
        // runs, and yet a thumbnail fetch occasionally fails having got no answer at all: seen in the
        // desktop smoke tests, where every other step passed and only the two thumbnails failed. The
        // cause is not known, so this does not claim to fix it. What it does is stop one lost request
        // from leaving a hole in the gallery.
        const response = await retry(
            () => api.get<Blob>(
                `${restApiUrl}/asset?id=${encodeURIComponent(assetId)}&type=${encodeURIComponent(assetType)}&db=${encodeURIComponent(databasePath)}`,
                {
                    responseType: "blob",
                }
            ),
            ASSET_REQUEST_ATTEMPTS,
            ASSET_RETRY_DELAY_MS,
            1
        );
        return response.data;
    }

    //
    // Gets a gallery item by id.
    //
    function getItemById(assetId: string): IGalleryItem | undefined {
        return loadedAssets.current[assetId];
    }

    //
    // Cancels an in-progress database load and cleans up its subscriptions.
    //
    function cancelDatabaseLoad(_dbPath: string): void {
        if (currentLoadQueue.current) {
            currentLoadQueue.current.shutdown();
            currentLoadQueue.current = undefined;
        }
        if (unsubscribeCurrentLoad.current) {
            unsubscribeCurrentLoad.current();
            unsubscribeCurrentLoad.current = undefined;
        }
    }

    //
    // Load assets into memory.
    //
    async function loadAssets(dbPath: string) {
        if (!dbPath) {
            throw new Error("Database path is required");
        }

        // If a load is already in progress for the same database path, just return
        if (loadingDatabasePath.current === dbPath) {
            log.info(`[loadAssets] Load already in progress for database: ${dbPath}, skipping`);
            return;
        }

        // If a load is in progress for a different database path, cancel it
        if (loadingDatabasePath.current !== undefined) {
            log.info(`[loadAssets] Cancelling previous load for database: ${loadingDatabasePath.current}`);
            cancelDatabaseLoad(loadingDatabasePath.current);
        }
    
        log.info(`[loadAssets] Starting load for database: "${dbPath}"`);
        loadingDatabasePath.current = dbPath;
        setIsLoading(true);

        //
        // Start with no assets.
        // This clears out any existing database of assets.
        //
        log.info(`[loadAssets] Clearing loadedAssets.current`);
        loadedAssets.current = {};

        //
        // Pass a gallery reset down the line.
        // This is the starting point for incremental gallery loading.
        //
        onReset.current.invoke();

        const queue = new TaskQueue(uuidGenerator, dbPath);
        currentLoadQueue.current = queue;

        // Store the database path at the time the load started
        const currentDatabasePath = dbPath;

        // Set up listener for task completion before queuing the task
        const unsubscribeComplete = queue.onTaskComplete<ILoadAssetsData, ILoadAssetsResult>((result) => {
            if (result.type === "load-assets") {
                if (result.status === TaskStatus.Succeeded) {
                    log.info(`Load assets task completed: ${result.outputs?.totalAssets} assets loaded`);
                }
                else {
                    log.error(`Load assets task failed: ${result.errorMessage}`);
                }

                if (result.inputs?.databasePath === currentDatabasePath) {
                    loadingDatabasePath.current = undefined;
                    setIsLoading(false);

                    if (result.status !== TaskStatus.Succeeded) {
                        // Loading failed — cancel pending tasks and unsubscribe.
                        cancelDatabaseLoad(currentDatabasePath);
                    }
                    else {
                        // Loading succeeded — unsubscribe callbacks. Any prefetch task will still
                        // run in the queue but we don't need to track its completion.
                        if (unsubscribeCurrentLoad.current) {
                            unsubscribeCurrentLoad.current();
                            unsubscribeCurrentLoad.current = undefined;
                        }
                    }
                }
            }
        });

        // Receive asset pages.
        const unsubscribeMessage = queue.onTaskMessage("asset-page", data => {
            // Discard messages that belong to a different (now-closed) database.
            if (data.message.databasePath !== currentDatabasePath) {
                return;
            }

            // Message is guaranteed to be an asset-page due to the filter
            if (data.message.batch && data.message.batch.length > 0) {
                _onNewItems(data.message.batch);
            }
        });

        unsubscribeCurrentLoad.current = () => {
            unsubscribeComplete();
            unsubscribeMessage();
        };

        // Queue the load-assets task using the same queue instance with database path
        loadAssetsApi(queue, dbPath);
    }

    //
    // Listen for database-opened and database-closed events from platform.
    //
    useEffect(() => {
        // Subscribe to database events
        const unsubscribeOpened = platform.onDatabaseOpened((dbPath: string) => {
            if (databasePath) {
                closeDatabase().catch(err => {
                    log.exception('Error closing database:', err as Error);
                });
            }
            setDatabasePath(dbPath);
        });

        const unsubscribeClosed = platform.onDatabaseClosed(() => {
            closeDatabase().catch(err => {
                log.exception('Error closing database:', err as Error);
            });
        });

        return () => {
            unsubscribeOpened();
            unsubscribeClosed();
        };
    }, [platform]);

    //
    // Reload the open database when the platform says its content changed underneath us.
    //
    // On mobile the background import runs while the WebView is suspended, so the messages that
    // would have added each photo to the gallery were sent while nothing was listening. A reload is
    // the only way back to the truth: there is no record of what was missed.
    //
    useEffect(() => {
        return platform.onDatabaseContentChanged(() => {
            if (!databasePath) {
                return;
            }

            loadAssets(databasePath).catch(err => {
                log.exception('Error reloading the database after it changed in the background:', err as Error);
            });
        });
    }, [platform, databasePath]);

    //
    // Subscribe to sync-started and sync-completed events from the platform.
    //
    useEffect(() => {
        const unsubscribeStarted = platform.onSyncStarted(() => {
            setIsSyncing(true);
        });

        const unsubscribeCompleted = platform.onSyncCompleted(() => {
            setIsSyncing(false);
        });

        return () => {
            unsubscribeStarted();
            unsubscribeCompleted();
        };
    }, [platform]);

    //
    // Subscribe to incremental sync-batch task messages and apply changes live to the gallery.
    //
    useEffect(() => {
        const unsubscribeSyncBatch = queueBackend.onTaskMessage("sync-batch", (data) => {
            const batch = data.message as ISyncBatchMessage;
            if (batch.databasePath !== databasePath) {
                return;
            }

            if (batch.added.length > 0) {
                _onNewItems(batch.added);
            }

            if (batch.updated.length > 0) {
                for (const asset of batch.updated) {
                    loadedAssets.current[asset._id] = asset;
                }
                onItemsUpdated.current.invoke({ assetIds: batch.updated.map(asset => asset._id) });
            }

            if (batch.deletedIds.length > 0) {
                for (const assetId of batch.deletedIds) {
                    delete loadedAssets.current[assetId];
                }
                onItemsDeleted.current.invoke({ assetIds: batch.deletedIds });
            }
        });

        return () => { unsubscribeSyncBatch(); };
    }, [databasePath]);

    //
    // Subscribe to import-success task messages and add newly imported assets to the gallery
    // immediately, so the user sees them without needing to reload.
    //
    // Automatic import arrivals come down the same path as manual ones. That is the point: a photo
    // that turned up on its own should land in the gallery exactly as one the user imported does,
    // rather than through a second arrival route that can drift out of step with the first.
    //
    useEffect(() => {
        const unsubscribeImportSuccess = platform.onTaskMessage((_taskId, message) => {
            if (message.type !== 'import-success') {
                return;
            }

            const asset = message.asset as IAsset | undefined;
            if (!asset) {
                return;
            }

            // An import writes to the database it was pointed at, which is not necessarily the one on
            // screen: automatic import uses the default database. An arrival in another database is
            // not this gallery's to show, and one taken in before this database has loaded is shown
            // twice: once now and once by the load. Both are the same check.
            if (!databasePath || message.databasePath !== databasePath) {
                return;
            }

            if (message.source === 'automatic') {
                // Only automatic arrivals are marked. A photo the user imported is something they
                // are already watching happen, so animating it would be noise.
                markRecentArrival(asset._id, Date.now());
            }

            _onNewItems([asset]);
        });

        return () => { unsubscribeImportSuccess(); };
    }, [platform, databasePath]);

    //
    // Load assets when database path changes.
    //
    useEffect(() => {
        if (databasePath) {
            loadAssets(databasePath)
                .catch(err => {
                    log.exception(`Failed to load assets:`, err as Error);
                });
        }

        // Cleanup: cancel tasks and unsubscribe if component unmounts or database path changes
        return () => {
            if (databasePath) {
                cancelDatabaseLoad(databasePath);
            }
            loadingDatabasePath.current = undefined;
        };
    }, [databasePath]);

    const value: IAssetDatabase = {
        // Gallery source.
        isLoading,
        isSyncing,
        isWorking,
        isReadOnly: false,
        getAssets,
        onReset: onReset.current,
        onNewItems: onNewItems.current,
        onItemsUpdated: onItemsUpdated.current,
        onItemsDeleted: onItemsDeleted.current,
        updateAsset,
        updateAssets,
        addArrayValue,
        removeArrayValue,
        deleteAssets,
        loadAsset,
        getItemById,

        // Asset database source.
        assetUrl: (assetId, assetType) => `${restApiUrl}/asset?id=${encodeURIComponent(assetId)}&type=${encodeURIComponent(assetType)}&db=${encodeURIComponent(databasePath || "")}`,
        databasePath,
        setDatabasePath,
        closeDatabase,
        moveToDatabase,
        selectAndOpenDatabase,
        createDatabase,
        createDatabaseAtPath,
        openDatabase,
        downloadAsset,
        downloadAssets,
    };
    
    return (
        <AssetDatabaseContext.Provider value={value} >
            <GallerySourceContext.Provider value={value} >
                {children}
            </GallerySourceContext.Provider>
        </AssetDatabaseContext.Provider>
    );
}

export const AssetDatabaseContext = createContext<IAssetDatabase | undefined>(undefined);

//
// Use the asset database in a component.
//
export function useAssetDatabase(): IAssetDatabase {
    const context = useContext(AssetDatabaseContext);
    if (!context) {
        throw new Error(`AssetDatabaseContext is not set!.`);
    }
    return context;
}