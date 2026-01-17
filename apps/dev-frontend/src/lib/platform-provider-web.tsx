import React, { ReactNode, useCallback } from "react";
import { PlatformContextProvider, type IPlatformContext } from "user-interface";

export interface IPlatformProviderWebProps {
    children: ReactNode | ReactNode[];
}

//
// Web-specific platform context provider.
// Provides stub implementations for web environment (database opening not supported in web).
//
export function PlatformProviderWeb({ children }: IPlatformProviderWebProps) {
    const openDatabase = useCallback(async (): Promise<void> => {
        // Database opening via file dialog is not supported in web environment
        throw new Error("Database opening is not supported in web environment. Use openDatabase(path) directly instead.");
    }, []);

    const onDatabaseOpened = useCallback((callback: (databasePath: string) => void): (() => void) => {
        // No-op: database-opened events are not used in web environment
        return () => {
            // Unsubscribe (no-op)
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

