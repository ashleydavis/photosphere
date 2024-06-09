import React, { ReactNode, createContext, useContext, useEffect, useState } from "react";
import { IUser } from "../def/user";
import { useIndexeddb } from "./indexeddb-context";
import { useOnline } from "../lib/use-online";
import { useApi } from "./api-context";

export interface IUserContext {
    //
    // The current user, if known.
    //
    user: IUser | undefined;
}

const UserContext = createContext<IUserContext | undefined>(undefined);

export interface IProps {
    children: ReactNode | ReactNode[];
}

export function UserContextProvider({ children }: IProps) {
    
    const { isOnline } = useOnline();
    const indexeddb = useIndexeddb();
    const api = useApi();
    const [ user, setUser ] = useState<IUser | undefined>(undefined);

    //
    // Loads the local user's details.
    //
    async function loadLocalUser(): Promise<void> {
        const userId = localStorage.getItem("userId");
        if (!userId) {
            return undefined;
        }

        const userDatabase = indexeddb.databases.database("user");
        const user = await userDatabase.collection<IUser>("user").getOne(userId);
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
                const userDatabase = indexeddb.databases.database("user");
                await userDatabase.collection("user").setOne("user", user);
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

    const value: IUserContext = {
        user,
    };
    
    return (
        <UserContext.Provider value={value} >
            {children}
        </UserContext.Provider>
    );
}

//
// Get the user object.
//
export function useUser() {
    const context = useContext(UserContext);
    if (!context) {
        throw new Error(`UserContext is not set! Add UserContext to the component tree.`);
    }
    return context;
}
