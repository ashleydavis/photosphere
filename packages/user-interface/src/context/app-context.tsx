import React, { ReactNode, createContext, useContext, useEffect, useState } from "react";
import { useOnline } from "../lib/use-online";
import { useApi } from "./api-context";
import { ISets } from "defs";

export interface IAppContext {
    //
    // The current sets that are available.
    //
    sets: ISets | undefined;
}

const AppContext = createContext<IAppContext | undefined>(undefined);

export interface IProps {
    children: ReactNode | ReactNode[];
}

export function AppContextProvider({ children }: IProps) {
    
    const { isOnline } = useOnline();
    const api = useApi();

    //
    // Available sets of assets.
    //
    const [ sets, setSets ] = useState<ISets | undefined>(undefined);

    //
    // Loads data from the backend.
    //
    async function load(): Promise<void> {
        if (isOnline) {
            const sets = await await api.getSets();
            if (sets) {
                setSets(sets);
                return;
            }
        }
    }

    useEffect(() => {
        load()
            .catch(err => {
                console.error(`Failed to load sets:`);
                console.error(err)            
            });
    }, [api.isInitialised, isOnline]);

    const value: IAppContext = {
        sets,
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
