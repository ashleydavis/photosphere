import React, { ReactNode, createContext, useContext } from "react";

//
// Unsubscribe function type for event listeners.
//
export type Unsubscribe = () => void;

//
// Platform-specific operations interface.
// Implemented by Electron for desktop and Capacitor for mobile.
//
export interface IPlatformContext {
    //
    // Opens a database file dialog.
    // The selected database path will be sent via the database-opened event.
    //
    openDatabase: () => Promise<void>;

    //
    // Subscribes to database opened events.
    // Returns an unsubscribe function.
    //
    onDatabaseOpened: (callback: (databasePath: string) => void) => Unsubscribe;
}

const PlatformContext = createContext<IPlatformContext | undefined>(undefined);

export interface IPlatformContextProviderProps {
    children: ReactNode | ReactNode[];
    value: IPlatformContext;
}

//
// Platform context provider.
// Should be implemented by platform-specific code (Electron, Capacitor, etc.)
//
export function PlatformContextProvider({ children, value }: IPlatformContextProviderProps) {
    return (
        <PlatformContext.Provider value={value}>
            {children}
        </PlatformContext.Provider>
    );
}

//
// Get the platform context.
//
export function usePlatform(): IPlatformContext {
    const context = useContext(PlatformContext);
    if (!context) {
        throw new Error(`PlatformContext is not set! Add PlatformContextProvider to the component tree.`);
    }
    return context;
}

