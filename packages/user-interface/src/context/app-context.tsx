import React, { ReactNode, createContext, useContext, useEffect, useState } from "react";
import { usePlatform } from "./platform-context";

export interface IAppContext {
    //
    // Available media file databases (list of database paths).
    //
    dbs: string[];

    //
    // Removes a database from the recent databases list.
    //
    removeDatabase: (databasePath: string) => Promise<void>;
}

const AppContext = createContext<IAppContext | undefined>(undefined);

export interface IProps {
    children: ReactNode | ReactNode[];
}

export function AppContextProvider({ children }: IProps) {
    const platform = usePlatform();
    
    //
    // Available media file databases (list of database paths).
    //
    const [ dbs, setDbs ] = useState<string[]>([]);

    //
    // Loads data from the backend.
    //
    async function load(): Promise<void> {
        try {
            const databases = await platform.getRecentDatabases();
            setDbs(databases);
        }
        catch (err) {
            console.error(`Failed to load recent databases:`);
            console.error(err);
            setDbs([]);
        }
    }

    //
    // Removes a database from the recent databases list.
    //
    async function removeDatabase(databasePath: string): Promise<void> {
        await platform.removeDatabase(databasePath);
        // Reload the list
        await load();
    }

    useEffect(() => {
        load()
            .catch(err => {
                console.error(`Failed to load sets:`);
                console.error(err)            
            });
    }, [platform]);

    const value: IAppContext = {
        dbs,
        removeDatabase,
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
