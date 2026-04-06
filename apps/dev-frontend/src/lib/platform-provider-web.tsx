import React, { ReactNode, useCallback, useEffect, useRef } from "react";
import { PlatformContextProvider, ConfigContextProvider, createConfig, type IPlatformContext } from "user-interface";

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
    };

    //
    // Sends a request over WebSocket and waits for a response matching the given type.
    //
    function sendAndWait<T>(request: object, responseType: string): Promise<T> {
        return new Promise((resolve, reject) => {
            const timeout = setTimeout(() => {
                reject(new Error(`Timeout waiting for ${responseType}`));
            }, 5000);

            const handleMessage = (event: MessageEvent) => {
                try {
                    const messageData = JSON.parse(event.data.toString());
                    if (messageData.type === responseType) {
                        clearTimeout(timeout);
                        ws.removeEventListener('message', handleMessage);
                        resolve(messageData.value as T);
                    }
                    else if (messageData.type === "error") {
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
            ws.send(JSON.stringify(request));
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

