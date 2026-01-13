import React, { ReactNode, createContext, useContext, useEffect, useState } from "react";
import { IMediaFileDatabases } from "defs";

export interface IAppContext {
    //
    // Available media file databases.
    //
    dbs: IMediaFileDatabases | undefined;
}

const AppContext = createContext<IAppContext | undefined>(undefined);

export interface IProps {
    children: ReactNode | ReactNode[];
}

export function AppContextProvider({ children }: IProps) {
    
    //
    // Available media file databases.
    //
    const [ dbs, setDbs ] = useState<IMediaFileDatabases | undefined>(undefined);

    //
    // Loads data from the backend.
    //
    async function load(): Promise<void> {
        // No databases loaded by default - user must open a database
        setDbs(undefined);
    }

    useEffect(() => {
        load()
            .catch(err => {
                console.error(`Failed to load sets:`);
                console.error(err)            
            });
    }, []);

    const value: IAppContext = {
        dbs,
    };
    
    return (
        <AppContext.Provider value={value} >
            {children}
        </AppContext.Provider>
    );
}

//
// Get the app context.
//
export function useApp() {
    const context = useContext(AppContext);
    if (!context) {
        throw new Error(`AppContext is not set! Add AppContext to the component tree.`);
    }
    return context;
}
