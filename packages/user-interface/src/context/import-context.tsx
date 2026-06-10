import React, { createContext, useCallback, useContext, useEffect, useRef, useState } from "react";
import { TaskQueue } from "task-queue";
import type { IUuidGenerator } from "utils";
import { usePlatform } from "./platform-context";
import type { IImportSession, IPlatformContext } from "./platform-context";
import { useAssetDatabase } from "./asset-database-source";
import { useUuidGenerator } from "./uuid-generator-context";

//
// Dependencies required by the standalone import-orchestration helpers below.
// Decoupled from React context so the helpers can be exercised by unit tests
// with a mocked platform and queue backend.
//
export interface IImportOrchestrationDeps {
    // Platform context, used for the open-folder and open-files pickers.
    platform: Pick<IPlatformContext, "pickFolder" | "pickFiles">;

    // Path of the currently open database; when undefined all helpers return undefined.
    databasePath: string | undefined;

    // Uuid generator used to mint session ids and task ids.
    uuidGenerator: IUuidGenerator;
}

//
// Queues an import-assets task for the given paths and returns the resulting session info.
// Returns undefined if no database is open.
//
export function startImportWithPaths(deps: IImportOrchestrationDeps, paths: string[]): IImportSession | undefined {
    if (!deps.databasePath) {
        return undefined;
    }

    const sessionId = deps.uuidGenerator.generate();
    const queue = new TaskQueue(deps.uuidGenerator, sessionId);
    queue.onTaskComplete(() => queue.shutdown());
    const importAssetsTaskId = queue.addTask("import-assets", {
        paths,
        storageDescriptor: { databasePath: deps.databasePath },
        sessionId,
        dryRun: false,
    }, sessionId);
    return { importAssetsTaskId, sessionId };
}

//
// Imports from the given directory paths, or shows a directory picker when paths is omitted.
// Returns undefined if no database is open or the user cancelled the picker.
//
export async function importDirectories(deps: IImportOrchestrationDeps, paths?: string[]): Promise<IImportSession | undefined> {
    if (!deps.databasePath) {
        return undefined;
    }

    let resolvedPaths = paths;
    if (!resolvedPaths || resolvedPaths.length === 0) {
        const folder = await deps.platform.pickFolder({ title: "Import Directory" });
        if (!folder) {
            return undefined;
        }
        resolvedPaths = [folder];
    }

    return startImportWithPaths(deps, resolvedPaths);
}

//
// Imports the given files, or shows a multi-file picker when paths is omitted.
// Returns undefined if no database is open or the user cancelled the picker.
//
export async function importFiles(deps: IImportOrchestrationDeps, paths?: string[]): Promise<IImportSession | undefined> {
    if (!deps.databasePath) {
        return undefined;
    }

    let resolvedPaths = paths;
    if (!resolvedPaths || resolvedPaths.length === 0) {
        resolvedPaths = await deps.platform.pickFiles("Import Files");
        if (!resolvedPaths || resolvedPaths.length === 0) {
            return undefined;
        }
    }

    return startImportWithPaths(deps, resolvedPaths);
}

//
// Import status lifecycle for the current import session.
//
export type ImportStatus = 'idle' | 'running' | 'completed' | 'cancelled';

//
// Per-item status within the import list.
//
export type ImportItemStatus = 'pending' | 'success' | 'failure' | 'skipped';

//
// A single item in the import list representing one file being imported.
//
export interface IImportItem {
    // The asset ID as stored (or attempted to be stored) in the database.
    assetId: string;

    // The original logical path of the file (e.g. photos/holiday/img001.jpg).
    logicalPath: string;

    // Current status of this item's import.
    status: ImportItemStatus;

    // Base64-encoded JPEG micro-thumbnail. Populated when status transitions to 'success'.
    // Undefined while pending, on failure, on skip, or when no thumbnail was generated.
    micro?: string;
}

//
// Value provided by ImportContext.
//
export interface IImportContext {
    // Current import lifecycle status.
    status: ImportStatus;

    // Ordered list of all items seen in the current import session, in arrival order.
    importItems: IImportItem[];

    // Imports the given directories and sets status to 'running'.
    // When paths are supplied they are used directly; when omitted a directory picker is shown.
    // Returns false if no database is open or the user cancelled the picker.
    startImportDirectories: (paths?: string[]) => Promise<boolean>;

    // Imports the given files and sets status to 'running'.
    // When paths are supplied they are used directly; when omitted a file picker is shown.
    // Returns false if no database is open or the user cancelled the picker.
    startImportFiles: (paths?: string[]) => Promise<boolean>;

    // Cancels the running import.
    cancelImport: () => Promise<void>;

    // Resets import state back to idle, clearing the list.
    clearImport: () => void;
}

const ImportContext = createContext<IImportContext | undefined>(undefined);

export interface IImportContextProviderProps {
    // Child components that can access the import context.
    children: React.ReactNode | React.ReactNode[];
}

//
// Provider component for the import context.
// Manages all import state and subscribes to worker events from the platform.
//
export function ImportContextProvider({ children }: IImportContextProviderProps) {
    const platform = usePlatform();
    const { databasePath } = useAssetDatabase();
    const uuidGenerator = useUuidGenerator();

    // Current lifecycle status of the import session.
    const [status, setStatus] = useState<ImportStatus>('idle');

    // Ordered list of all items seen in the current import session.
    const [importItems, setImportItems] = useState<IImportItem[]>([]);

    // Session info recorded when an import starts.
    const sessionRef = useRef<IImportSession | null>(null);

    // Whether the add-paths task has completed (scanning is done).
    const addPathsDoneRef = useRef<boolean>(false);

    // Stable ref to the current status so event handlers can read it without stale closures.
    const statusRef = useRef<ImportStatus>('idle');

    //
    // Keeps statusRef in sync with state.
    //
    useEffect(() => {
        statusRef.current = status;
    }, [status]);

    //
    // Checks whether all items are resolved and scanning is done, then marks the import complete.
    // Must be called inside a setImportItems updater to receive the latest items synchronously.
    //
    const checkCompletionWithItems = useCallback((currentItems: IImportItem[]): void => {
        if (statusRef.current !== 'running') {
            return;
        }

        if (!addPathsDoneRef.current) {
            return;
        }

        const allResolved = currentItems.every(item => item.status !== 'pending');
        if (allResolved) {
            setStatus('completed');
            statusRef.current = 'completed';
        }
    }, []);

    //
    // Subscribe to task messages and task completion events from the platform.
    //
    useEffect(() => {
        const unsubscribeMessage = platform.onTaskMessage((_taskId, message) => {
            // Only process messages while an import is running.
            if (statusRef.current !== 'running') {
                return;
            }

            const messageType = typeof message.type === 'string' ? message.type : undefined;

            if (messageType === 'import-pending') {
                const assetId = message.assetId as string;
                const logicalPath = message.logicalPath as string;
                const newItem: IImportItem = { assetId, logicalPath, status: 'pending' };
                setImportItems(prev => [...prev, newItem]);
            }
            else if (messageType === 'import-success') {
                const assetId = message.assetId as string;
                const micro = typeof message.micro === 'string' ? message.micro : undefined;
                setImportItems(prev => {
                    const updated = prev.map(item =>
                        item.assetId === assetId
                            ? { ...item, status: 'success' as ImportItemStatus, micro }
                            : item
                    );
                    checkCompletionWithItems(updated);
                    return updated;
                });
            }
            else if (messageType === 'import-failed') {
                const assetId = message.assetId as string;
                setImportItems(prev => {
                    const updated = prev.map(item =>
                        item.assetId === assetId
                            ? { ...item, status: 'failure' as ImportItemStatus }
                            : item
                    );
                    checkCompletionWithItems(updated);
                    return updated;
                });
            }
            else if (messageType === 'import-skipped') {
                const assetId = message.assetId as string;
                setImportItems(prev => {
                    const updated = prev.map(item =>
                        item.assetId === assetId
                            ? { ...item, status: 'skipped' as ImportItemStatus }
                            : item
                    );
                    checkCompletionWithItems(updated);
                    return updated;
                });
            }
        });

        const unsubscribeComplete = platform.onTaskComplete((taskId, _result) => {
            if (statusRef.current !== 'running') {
                return;
            }

            if (sessionRef.current && taskId === sessionRef.current.importAssetsTaskId) {
                addPathsDoneRef.current = true;

                // Use the functional updater to access the latest items for the completion check.
                setImportItems(currentItems => {
                    checkCompletionWithItems(currentItems);
                    return currentItems;
                });
            }
        });

        return () => {
            unsubscribeMessage();
            unsubscribeComplete();
        };
    }, [platform, checkCompletionWithItems]);

    //
    // Starts a session using the given session promise, records it, and transitions to 'running'.
    // Returns false if the session is undefined (no database open or user cancelled).
    //
    async function beginImportSession(sessionPromise: Promise<IImportSession | undefined>): Promise<boolean> {
        const session = await sessionPromise;
        if (!session) {
            return false;
        }

        sessionRef.current = session;
        addPathsDoneRef.current = false;
        setImportItems([]);
        setStatus('running');
        statusRef.current = 'running';
        return true;
    }

    //
    // Opens a directory picker (or uses the given paths) and starts an import.
    // Returns false if no database is open or the user cancelled the picker.
    //
    const startImportDirectories = useCallback(async (paths?: string[]): Promise<boolean> => {
        return beginImportSession(importDirectories({ platform, databasePath, uuidGenerator }, paths));
    }, [platform, databasePath, uuidGenerator]);

    //
    // Opens a file picker (or uses the given paths) and starts an import.
    // Returns false if no database is open or the user cancelled the picker.
    //
    const startImportFiles = useCallback(async (paths?: string[]): Promise<boolean> => {
        return beginImportSession(importFiles({ platform, databasePath, uuidGenerator }, paths));
    }, [platform, databasePath, uuidGenerator]);

    //
    // Cancels the running import by notifying the platform to stop all tasks in the session.
    //
    const cancelImport = useCallback(async (): Promise<void> => {
        if (sessionRef.current) {
            await platform.cancelTasks(sessionRef.current.sessionId);
        }

        setStatus('cancelled');
        statusRef.current = 'cancelled';
    }, [platform]);

    //
    // Resets all import state back to idle, clearing the item list.
    //
    const clearImport = useCallback((): void => {
        sessionRef.current = null;
        addPathsDoneRef.current = false;
        setImportItems([]);
        setStatus('idle');
        statusRef.current = 'idle';
    }, []);

    //
    // Clears import state whenever the active database changes or is closed.
    // This prevents stale import results from a previous database leaking into a new one.
    // Runs on initial mount too, which is harmless because state is already empty,
    // and only re-runs when databasePath actually changes (starting an import does not
    // change databasePath, so an in-flight import is never clobbered by this effect).
    //
    useEffect(() => {
        clearImport();
    }, [databasePath, clearImport]);

    const contextValue: IImportContext = {
        status,
        importItems,
        startImportDirectories,
        startImportFiles,
        cancelImport,
        clearImport,
    };

    return (
        <ImportContext.Provider value={contextValue}>
            {children}
        </ImportContext.Provider>
    );
}

//
// Hook to access the import context.
//
export function useImport(): IImportContext {
    const context = useContext(ImportContext);
    if (!context) {
        throw new Error(`ImportContext is not set! Add ImportContextProvider to the component tree.`);
    }
    return context;
}
