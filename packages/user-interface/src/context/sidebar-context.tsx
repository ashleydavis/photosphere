import React, { ReactNode, createContext, useContext, useState } from "react";

export interface ISidebarContext {
    //
    // Set to true to open the sidebar.
    //
    sidebarOpen: boolean;
    setSidebarOpen: (open: boolean) => void;
}

const SidebarContext = createContext<ISidebarContext | undefined>(undefined);

export interface ISidebarContextProviderProps {
    children: ReactNode | ReactNode[];
}

export function SidebarContextProvider({ children }: ISidebarContextProviderProps) {
    //
    // Set to true to open the sidebar.
    //
    const [sidebarOpen, setSidebarOpen] = useState<boolean>(false);

    const value: ISidebarContext = {
        sidebarOpen,
        setSidebarOpen,
    };
    
    return (
        <SidebarContext.Provider value={value}>
            {children}
        </SidebarContext.Provider>
    );
}

//
// Get the sidebar context.
//
export function useSidebar() {
    const context = useContext(SidebarContext);
    if (!context) {
        throw new Error(`SidebarContext is not set! Add SidebarContextProvider to the component tree.`);
    }
    return context;
}

