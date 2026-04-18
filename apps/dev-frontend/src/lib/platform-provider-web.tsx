import React, { ReactNode, useCallback, useEffect, useRef } from "react";
import { PlatformContextProvider, ConfigContextProvider, createConfig, type IPlatformContext, type IImportSession, type IToolsStatus, type IDownloadAssetItem, type IShowNotificationData, type IDatabaseEntry, type IDatabaseSecrets, convertToPng } from "user-interface";

const restApiUrl = "http://localhost:3001";

// Monotonically increasing counter used to correlate WebSocket request/response pairs.
let nextRequestId = 0;

export interface IPlatformProviderWebProps {
    children: ReactNode | ReactNode[];
    ws: WebSocket;
}

//
// Web-specific platform context provider.
// Provides database opening functionality via WebSocket to dev-server.
//
export function PlatformProviderWeb({ children, ws }: IPlatformProviderWebProps) {
    // Store callbacks for database-opened events
    const openedCallbacksRef = useRef<Set<(databasePath: string) => void>>(new Set());
    
    // Store callbacks for database-closed events
    const closedCallbacksRef = useRef<Set<() => void>>(new Set());

    // Store callbacks for sync-started events
    const syncStartedCallbacksRef = useRef<Set<() => void>>(new Set());

    // Store callbacks for sync-completed events
    const syncCompletedCallbacksRef = useRef<Set<() => void>>(new Set());

    // Set up message listener for database-opened events
    useEffect(() => {
        const handleMessage = (event: MessageEvent) => {
            try {
                const messageData = JSON.parse(event.data.toString());
                
                if (messageData.type === "database-opened") {
                    // Notify all subscribers
                    openedCallbacksRef.current.forEach(callback => {
                        callback(messageData.databasePath);
                    });
                }
                else if (messageData.type === "database-closed") {
                    // Notify all subscribers
                    closedCallbacksRef.current.forEach(callback => {
                        callback();
                    });
                }
                else if (messageData.type === "sync-started") {
                    syncStartedCallbacksRef.current.forEach(cb => cb());
                }
                else if (messageData.type === "sync-completed") {
                    syncCompletedCallbacksRef.current.forEach(cb => cb());
                }
            }
            catch (error) {
                // Log parse errors but don't throw - other message handlers may process this message
                console.error("Error parsing database-opened message:", error);
            }
        };

        ws.addEventListener('message', handleMessage);

        return () => {
            ws.removeEventListener('message', handleMessage);
        };
    }, [ws]);

    const openDatabase = useCallback(async (): Promise<void> => {
        // Send open-database request to server
        ws.send(JSON.stringify({
            type: "open-database",
        }));
    }, [ws]);

    const createDatabase = useCallback(async (): Promise<void> => {
        // Send create-database request to server
        ws.send(JSON.stringify({
            type: "create-database",
        }));
    }, [ws]);

    const onDatabaseOpened = useCallback((callback: (databasePath: string) => void): (() => void) => {
        // Add callback to set
        openedCallbacksRef.current.add(callback);

        // Return unsubscribe function
        return () => {
            openedCallbacksRef.current.delete(callback);
        };
    }, []);

    const onDatabaseClosed = useCallback((callback: () => void): (() => void) => {
        // Add callback to set
        closedCallbacksRef.current.add(callback);

        // Return unsubscribe function
        return () => {
            closedCallbacksRef.current.delete(callback);
        };
    }, []);

    const notifyDatabaseOpened = useCallback(async (databasePath: string): Promise<void> => {
        await sendAndWait<void>({ type: "notify-database-opened", databasePath }, "notify-database-opened-ack");
    }, [ws]);

    const notifyDatabaseClosed = useCallback(async (): Promise<void> => {
        await sendAndWait<void>({ type: "notify-database-closed" }, "notify-database-closed-ack");
    }, [ws]);

    const onThemeChanged = useCallback((callback: (theme: 'light' | 'dark' | 'system') => void): (() => void) => {
        // No-op for web platform
        return () => {};
    }, []);

    const notifyDatabaseEdited = useCallback((): void => {
        ws.send(JSON.stringify({ type: "notify-database-edited" }));
    }, [ws]);

    const onSyncStarted = useCallback((callback: () => void): (() => void) => {
        syncStartedCallbacksRef.current.add(callback);
        return () => {
            syncStartedCallbacksRef.current.delete(callback);
        };
    }, []);

    const onSyncCompleted = useCallback((callback: () => void): (() => void) => {
        syncCompletedCallbacksRef.current.add(callback);
        return () => {
            syncCompletedCallbacksRef.current.delete(callback);
        };
    }, []);

    const downloadAsset = useCallback(async (assetId: string, assetType: string, filename: string, contentType: string, databasePath: string): Promise<void> => {
        const url = `${restApiUrl}/asset?id=${encodeURIComponent(assetId)}&type=${encodeURIComponent(assetType)}&db=${encodeURIComponent(databasePath)}`;
        const response = await fetch(url);
        const blob = await response.blob();
        const typedBlob = new Blob([blob], { type: contentType });
        const downloadUrl = URL.createObjectURL(typedBlob);
        const a = document.createElement("a");
        a.href = downloadUrl;
        a.download = filename;
        a.click();
        URL.revokeObjectURL(downloadUrl);
    }, []);

    const downloadAssets = useCallback(async (assets: IDownloadAssetItem[], databasePath: string): Promise<void> => {
        for (const asset of assets) {
            await downloadAsset(asset.assetId, asset.assetType, asset.filename, asset.contentType, databasePath);
        }
    }, [downloadAsset]);

    const copyToClipboard = useCallback(async (blob: Blob, _contentType: string): Promise<void> => {
        const pngBlob = await convertToPng(blob);
        await navigator.clipboard.write([new ClipboardItem({ "image/png": pngBlob })]);
    }, []);


    const onShowNotification = useCallback((_callback: (data: IShowNotificationData) => void): (() => void) => {
        // No-op for web platform.
        return () => {};
    }, []);

    const openFolder = useCallback(async (_folderPath: string): Promise<void> => {
        // Not applicable on web platform.
    }, []);

    const onMenuAction = useCallback((_action: string, _callback: () => void): (() => void) => {
        // No-op for web platform.
        return () => {};
    }, []);

    const importAssets = useCallback(async (_paths?: string[]): Promise<IImportSession | undefined> => {
        // Not supported on web platform.
        return undefined;
    }, []);

    const getPathForFile = useCallback((_file: File): string | undefined => {
        // Not supported on web platform.
        return undefined;
    }, []);

    const checkTools = useCallback(async (): Promise<IToolsStatus> => {
        // All tools assumed available on web platform.
        return {
            magick: { available: true },
            ffprobe: { available: true },
            ffmpeg: { available: true },
            allAvailable: true,
            missingTools: [],
        };
    }, []);

    const checkDatabaseExists = useCallback(async (_databasePath: string): Promise<boolean> => {
        // Always returns true on web platform; file system is not accessible.
        return true;
    }, []);

    const onTaskMessage = useCallback((_handler: (taskId: string, message: Record<string, unknown>) => void): (() => void) => {
        // No-op on web platform; no task workers.
        return () => {};
    }, []);

    const onTaskComplete = useCallback((_handler: (taskId: string, result: Record<string, unknown>) => void): (() => void) => {
        // No-op on web platform; no task workers.
        return () => {};
    }, []);

    const cancelTasks = useCallback(async (_sessionId: string): Promise<void> => {
        // No-op on web platform; no tasks to cancel.
    }, []);

    const getDatabases = useCallback(async () => {
        return [];
    }, []);

    const addDatabase = useCallback(async (entry: Omit<IDatabaseEntry, "id">): Promise<IDatabaseEntry> => {
        return { ...entry, id: Math.random().toString(36).slice(2, 10) };
    }, []);

    const updateDatabase = useCallback(async (_entry: IDatabaseEntry): Promise<void> => {
    }, []);

    const removeDatabaseEntry = useCallback(async (_id: string): Promise<void> => {
    }, []);

    const getDatabaseSecrets = useCallback(async (_id: string): Promise<IDatabaseSecrets> => {
        return {};
    }, []);

    const setDatabaseSecrets = useCallback(async (_id: string, _secrets: IDatabaseSecrets): Promise<void> => {
    }, []);

    const pickFolder = useCallback(async () => {
        return undefined;
    }, []);

    const platformContext: IPlatformContext = {
        openDatabase,
        createDatabase,
        onDatabaseOpened,
        onDatabaseClosed,
        notifyDatabaseOpened,
        notifyDatabaseClosed,
        onThemeChanged,
        notifyDatabaseEdited,
        onSyncStarted,
        onSyncCompleted,
        downloadAsset,
        downloadAssets,
        copyToClipboard,
        onShowNotification,
        openFolder,
        onMenuAction,
        importAssets,
        getPathForFile,
        checkTools,
        checkDatabaseExists,
        onTaskMessage,
        onTaskComplete,
        cancelTasks,
        getDatabases,
        addDatabase,
        updateDatabase,
        removeDatabaseEntry,
        getDatabaseSecrets,
        setDatabaseSecrets,
        pickFolder,
    };

    //
    // Sends a request over WebSocket and waits for a response matching the given type and requestId.
    // A unique requestId is added to every request so that concurrent calls do not resolve
    // each other's promises when multiple "config-value" (or similar) messages are in flight.
    //
    function sendAndWait<T>(request: object, responseType: string): Promise<T> {
        const requestId = nextRequestId++;
        return new Promise((resolve, reject) => {
            const timeout = setTimeout(() => {
                reject(new Error(`Timeout waiting for ${responseType}`));
            }, 5000);

            const handleMessage = (event: MessageEvent) => {
                try {
                    const messageData = JSON.parse(event.data.toString());
                    if (messageData.type === responseType && messageData.requestId === requestId) {
                        clearTimeout(timeout);
                        ws.removeEventListener('message', handleMessage);
                        resolve(messageData.value as T);
                    }
                    else if (messageData.type === "error" && messageData.requestId === requestId) {
                        clearTimeout(timeout);
                        ws.removeEventListener('message', handleMessage);
                        reject(new Error(messageData.message || "Unknown error"));
                    }
                }
                catch (error) {
                    // Ignore parse errors for other message types
                }
            };

            ws.addEventListener('message', handleMessage);
            ws.send(JSON.stringify({ ...request, requestId }));
        });
    }

    const config = createConfig(
        (key) => sendAndWait<unknown>({ type: "get-config", key }, "config-value"),
        (key, value) => sendAndWait<void>({ type: "set-config", key, value }, "config-set")
    );

    return (
        <ConfigContextProvider value={config}>
            <PlatformContextProvider value={platformContext}>
                {children}
            </PlatformContextProvider>
        </ConfigContextProvider>
    );
}

