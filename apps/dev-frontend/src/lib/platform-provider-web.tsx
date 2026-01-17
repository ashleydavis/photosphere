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
    const callbacksRef = useRef<Set<(databasePath: string) => void>>(new Set());

    // Set up message listener for database-opened events
    useEffect(() => {
        const handleMessage = (event: MessageEvent) => {
            try {
                const messageData = JSON.parse(event.data.toString());
                
                if (messageData.type === "database-opened") {
                    // Notify all subscribers
                    callbacksRef.current.forEach(callback => {
                        callback(messageData.databasePath);
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
        callbacksRef.current.add(callback);

        // Return unsubscribe function
        return () => {
            callbacksRef.current.delete(callback);
        };
    }, []);

    const platformContext: IPlatformContext = {
        openDatabase,
        onDatabaseOpened,
    };

    return (
        <PlatformContextProvider value={platformContext}>
            {children}
        </PlatformContextProvider>
    );
}

