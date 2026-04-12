import React, { createContext, useCallback, useContext, useEffect, useRef, useState } from "react";
import { usePlatform } from "./platform-context";
import type { IImportSession } from "./platform-context";

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

    // Calls platform.importAssets(), records the session, and sets status to 'running'.
    // Returns false if the user cancelled the folder picker (importAssets returned undefined).
    startImport: () => Promise<boolean>;

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

            if (sessionRef.current && taskId === sessionRef.current.addPathsTaskId) {
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
    // Starts an import by calling platform.importAssets(). Records the session so progress
    // events can be correlated, and transitions status to 'running'.
    // Returns false if the user cancelled the folder picker.
    //
    const startImport = useCallback(async (): Promise<boolean> => {
        const session = await platform.importAssets();
        if (!session) {
            return false;
        }

        sessionRef.current = session;
        addPathsDoneRef.current = false;
        setImportItems([]);
        setStatus('running');
        statusRef.current = 'running';
        return true;
    }, [platform]);

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

    const contextValue: IImportContext = {
        status,
        importItems,
        startImport,
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
