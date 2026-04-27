import React, { ReactNode, createContext, useContext, useEffect, useState } from "react";
import { usePlatform, type IDatabaseEntry } from "./platform-context";
import { log } from "utils";

export interface IAppContext {
    //
    // Configured database entries.
    //
    dbs: IDatabaseEntry[];

    //
    // Removes a database entry by id.
    //
    removeDatabase: (id: string) => Promise<void>;
}

const AppContext = createContext<IAppContext | undefined>(undefined);

export interface IProps {
    children: ReactNode | ReactNode[];
}

export function AppContextProvider({ children }: IProps) {
    const platform = usePlatform();

    //
    // Configured database entries.
    //
    const [ dbs, setDbs ] = useState<IDatabaseEntry[]>([]);

    //
    // Loads database entries from the platform.
    //
    async function load(): Promise<void> {
        try {
            const databases = await platform.getDatabases();
            setDbs(databases);
        }
        catch (err) {
            log.exception(`Failed to load databases:`, err as Error);
            setDbs([]);
        }
    }

    //
    // Removes a database entry by path.
    //
    async function removeDatabase(databasePath: string): Promise<void> {
        await platform.removeDatabaseEntry(databasePath);
        await load();
    }

    useEffect(() => {
        load()
            .catch(err => {
                log.exception(`Failed to load sets:`, err as Error);
            });
    }, [platform]);

    useEffect(() => {
        return platform.onDatabaseOpened(() => {
            load()
                .catch(err => {
                    log.exception(`Failed to reload recent databases after database opened:`, err as Error);
                });
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
