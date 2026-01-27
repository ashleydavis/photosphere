import React, { ReactNode, useCallback, useEffect, useRef } from "react";
import { PlatformContextProvider, type IPlatformContext } from "user-interface";

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

    const getRecentDatabases = useCallback(async (): Promise<string[]> => {
        return new Promise((resolve, reject) => {
            const timeout = setTimeout(() => {
                reject(new Error("Timeout waiting for recent databases"));
            }, 5000);

            const handleMessage = (event: MessageEvent) => {
                try {
                    const messageData = JSON.parse(event.data.toString());
                    if (messageData.type === "recent-databases") {
                        clearTimeout(timeout);
                        ws.removeEventListener('message', handleMessage);
                        resolve(messageData.databases || []);
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
            ws.send(JSON.stringify({
                type: "get-recent-databases",
            }));
        });
    }, [ws]);

    const removeDatabase = useCallback(async (databasePath: string): Promise<void> => {
        return new Promise((resolve, reject) => {
            const timeout = setTimeout(() => {
                reject(new Error("Timeout waiting for database removal"));
            }, 5000);

            const handleMessage = (event: MessageEvent) => {
                try {
                    const messageData = JSON.parse(event.data.toString());
                    if (messageData.type === "database-removed") {
                        clearTimeout(timeout);
                        ws.removeEventListener('message', handleMessage);
                        resolve();
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
            ws.send(JSON.stringify({
                type: "remove-database",
                databasePath: databasePath,
            }));
        });
    }, [ws]);

    const notifyDatabaseOpened = useCallback(async (databasePath: string): Promise<void> => {
        // Add to recent databases for web platform
        return new Promise((resolve, reject) => {
            const timeout = setTimeout(() => {
                reject(new Error("Timeout waiting for adding recent database"));
            }, 5000);

            const handleMessage = (event: MessageEvent) => {
                try {
                    const messageData = JSON.parse(event.data.toString());
                    if (messageData.type === "database-added") {
                        clearTimeout(timeout);
                        ws.removeEventListener('message', handleMessage);
                        resolve();
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
            ws.send(JSON.stringify({
                type: "add-recent-database",
                databasePath: databasePath,
            }));
        });
    }, [ws]);

    const notifyDatabaseClosed = useCallback(async (): Promise<void> => {
        // Clear the last database
        return new Promise((resolve, reject) => {
            const timeout = setTimeout(() => {
                reject(new Error("Timeout waiting for clearing last database"));
            }, 5000);

            const handleMessage = (event: MessageEvent) => {
                try {
                    const messageData = JSON.parse(event.data.toString());
                    if (messageData.type === "last-database-cleared") {
                        clearTimeout(timeout);
                        ws.removeEventListener('message', handleMessage);
                        resolve();
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
            ws.send(JSON.stringify({
                type: "clear-last-database",
            }));
        });
    }, [ws]);

    const getTheme = useCallback(async (): Promise<'light' | 'dark' | 'system'> => {
        // No-op for web platform, default to system
        return 'system';
    }, []);

    const setTheme = useCallback(async (theme: 'light' | 'dark' | 'system'): Promise<void> => {
        // No-op for web platform
    }, []);

    const onThemeChanged = useCallback((callback: (theme: 'light' | 'dark' | 'system') => void): (() => void) => {
        // No-op for web platform
        return () => {
            // No-op
        };
    }, []);

    const platformContext: IPlatformContext = {
        openDatabase,
        onDatabaseOpened,
        onDatabaseClosed,
        getRecentDatabases,
        removeDatabase,
        notifyDatabaseOpened,
        notifyDatabaseClosed,
        getTheme,
        setTheme,
        onThemeChanged,
    };

    return (
        <PlatformContextProvider value={platformContext}>
            {children}
        </PlatformContextProvider>
    );
}

