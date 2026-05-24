import React, { ReactNode, useCallback, useEffect, useRef } from "react";
import { PlatformContextProvider, ConfigContextProvider, createConfig, type IPlatformContext, type IToolsStatus, type IShowNotificationData, type IUpdateAvailableData, type IDatabaseEntry, type ISharedSecretEntry, type IPickFolderOptions, convertToPng } from "user-interface";

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

        // Fire opened callbacks so UI components (e.g. recent databases list) refresh.
        openedCallbacksRef.current.forEach(callback => {
            callback(databasePath);
        });
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

    const copyToClipboard = useCallback(async (blob: Blob, _contentType: string): Promise<void> => {
        const pngBlob = await convertToPng(blob);
        await navigator.clipboard.write([new ClipboardItem({ "image/png": pngBlob })]);
    }, []);


    const onShowNotification = useCallback((_callback: (data: IShowNotificationData) => void): (() => void) => {
        // No-op for web platform.
        return () => {};
    }, []);

    const onUpdateAvailable = useCallback((_callback: (data: IUpdateAvailableData) => void): (() => void) => {
        // No-op for web platform. Host app store handles updates.
        return () => {};
    }, []);

    const openFolder = useCallback(async (_folderPath: string): Promise<void> => {
        // Not applicable on web platform.
    }, []);

    const onMenuAction = useCallback((_callback: (action: string) => void): (() => void) => {
        // No-op for web platform.
        return () => {};
    }, []);

    const onNavigate = useCallback((_callback: (page: string) => void): (() => void) => {
        // No-op for web platform.
        return () => {};
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

    const addDatabase = useCallback(async (entry: IDatabaseEntry): Promise<IDatabaseEntry> => {
        return entry;
    }, []);

    const updateDatabase = useCallback(async (_originalName: string, _entry: IDatabaseEntry): Promise<void> => {
    }, []);

    const removeDatabaseEntry = useCallback(async (_name: string): Promise<void> => {
    }, []);

    const findDatabase = useCallback(async (_name: string): Promise<IDatabaseEntry | undefined> => {
        return undefined;
    }, []);

    const pickFolder = useCallback(async (options?: IPickFolderOptions): Promise<string | undefined> => {
        return await sendAndWait<string | undefined>({ type: "pick-folder", options }, "pick-folder-result");
    }, [ws]);

    const pickFile = useCallback(async (defaultFilename: string): Promise<string | undefined> => {
        // The web browser has no native save dialog that returns a filesystem path. The web
        // save-asset task handler consumes the returned string as the download filename, so
        // pass the suggested filename straight through. Returning undefined would cancel the flow.
        return defaultFilename;
    }, []);

    const pickFiles = useCallback(async (title: string): Promise<string[] | undefined> => {
        return await sendAndWait<string[] | undefined>({ type: "pick-files", title }, "pick-files-result");
    }, [ws]);

    const listSecrets = useCallback(async (): Promise<ISharedSecretEntry[]> => {
        return [];
    }, []);

    const addSecret = useCallback(async (entry: ISharedSecretEntry, _value: string): Promise<ISharedSecretEntry> => {
        return entry;
    }, []);

    const updateSecret = useCallback(async (_originalName: string, _entry: ISharedSecretEntry, _value?: string): Promise<void> => {
    }, []);

    const deleteSecret = useCallback(async (_name: string): Promise<void> => {
    }, []);

    const getSecretValue = useCallback(async (_name: string): Promise<string | undefined> => {
        return undefined;
    }, []);

    const getRecentDatabases = useCallback(async (): Promise<IDatabaseEntry[]> => {
        return [];
    }, []);

    const removeRecentDatabaseName = useCallback(async (_name: string): Promise<void> => {
    }, []);

    const listS3Dirs = useCallback(async (_s3Key: string, _bucket: string, _prefix: string): Promise<string[]> => {
        return [];
    }, []);

    const startShareReceive = useCallback(async (_code: string): Promise<void> => {
        // Not supported on web platform.
    }, []);

    const waitShareReceive = useCallback(async (): Promise<unknown> => {
        // Not supported on web platform.
        return null;
    }, []);

    const cancelShareReceive = useCallback(async (): Promise<void> => {
        // Not supported on web platform.
    }, []);

    const waitForReceiver = useCallback(async (_payload: unknown, _code: string): Promise<unknown> => {
        // Not supported on web platform.
        return null;
    }, []);

    const sendToReceiver = useCallback(async (_endpoint: unknown): Promise<boolean> => {
        // Not supported on web platform.
        return false;
    }, []);

    const cancelShareSend = useCallback(async (): Promise<void> => {
        // Not supported on web platform.
    }, []);

    const importSharePayload = useCallback(async (_payload: unknown): Promise<void> => {
        // Not supported on web platform.
    }, []);

    const markUpdateAsShown = useCallback(async (_version: string): Promise<void> => {
        // No-op for web platform; update notifications are handled by the host app store.
    }, []);

    const markNewsAsShown = useCallback(async (_newsId: string): Promise<void> => {
        // No-op for web platform; news notifications are not surfaced as toasts here.
    }, []);

    const platformContext: IPlatformContext = {
        openDatabase,
        onDatabaseOpened,
        onDatabaseClosed,
        notifyDatabaseOpened,
        notifyDatabaseClosed,
        onThemeChanged,
        notifyDatabaseEdited,
        onSyncStarted,
        onSyncCompleted,
        copyToClipboard,
        onShowNotification,
        onUpdateAvailable,
        openFolder,
        onMenuAction,
        onNavigate,
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
        findDatabase,
        pickFolder,
        pickFile,
        pickFiles,
        listSecrets,
        addSecret,
        updateSecret,
        deleteSecret,
        getSecretValue,
        getRecentDatabases,
        removeRecentDatabaseName,
        listS3Dirs,
        startShareReceive,
        waitShareReceive,
        cancelShareReceive,
        waitForReceiver,
        sendToReceiver,
        cancelShareSend,
        importSharePayload,
        markUpdateAsShown,
        markNewsAsShown,
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

