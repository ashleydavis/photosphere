import React, { ReactNode, createContext, useContext, useEffect, useState } from "react";
import { useIndexeddb } from "./indexeddb-context";
import { useOnline } from "../lib/use-online";
import { useApi } from "./api-context";
import { IUser } from "defs";

export interface IAppContext {
    //
    // The current user, if known.
    //
    user: IUser | undefined;
}

const AppContext = createContext<IAppContext | undefined>(undefined);

export interface IProps {
    children: ReactNode | ReactNode[];
}

export function AppContextProvider({ children }: IProps) {
    
    const { isOnline } = useOnline();
    const { database } = useIndexeddb();
    const api = useApi();

    //
    // The current user.
    //
    const [ user, setUser ] = useState<IUser | undefined>(undefined);

    //
    // Loads the local user's details.
    //
    async function loadLocalUser(): Promise<void> {
        const userId = localStorage.getItem("userId");
        if (!userId) {
            return undefined;
        }

        const user = await database.collection<IUser>("users").getOne(userId);
        if (user) {
            setUser(user);
        }
        else {
            setUser(undefined);
        }
    }

    //
    // Loads the user's details.
    //
    async function loadUser(): Promise<void> {
        if (isOnline) {
            // Not able to load user details offline.
            const user = await await api.getUser();
            if (user) {
                //
                // Store user locally for offline use.
                //
                await database.collection("users").setOne(user);
                localStorage.setItem("userId", user._id);
                setUser(user);
                return;
            }
        }

        // Fallback to local user.
        await loadLocalUser();
    }

    useEffect(() => {
        loadUser()
            .catch(err => {
                console.error(`Failed to load user:`);
                console.error(err)            
            });
    }, [api.isInitialised, isOnline]);

    const value: IAppContext = {
        user,
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
