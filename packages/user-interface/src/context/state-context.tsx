import React, { ReactNode, createContext, useContext } from "react";
import type { IConfig } from "./config-context";

//
// The store for what the app remembers on its own, so the interface comes back the way it was left:
// which sidebar sections were collapsed, how the gallery was sorted, the folder a dialog last opened
// at, the searches that were merely run.
//
// The sibling of the config store, which holds what the user chose. They are separate contexts rather
// than one store that works out where each key belongs, because the caller always knows which of the
// two it wants: a collapsible section is storing state, and the theme toggle is storing a setting.
// Nothing has to decide at run time, and nothing has to keep a list of which key is which.
//
// The operations are the same as the config store's, so the interface is the same one. What differs is
// the file underneath: each platform backs this context with state.yaml and the config context with
// config.yaml.
//
const StateContext = createContext<IConfig | undefined>(undefined);

export interface IStateContextProviderProps {
    //
    // The store implementation to provide to the component tree.
    //
    value: IConfig;

    //
    // Child components that will have access to the store.
    //
    children: ReactNode | ReactNode[];
}

//
// Provides the state store to the component tree.
//
export function StateContextProvider({ value, children }: IStateContextProviderProps) {
    return (
        <StateContext.Provider value={value}>
            {children}
        </StateContext.Provider>
    );
}

//
// Returns the state store from context. Must be used within a StateContextProvider.
//
// A file that also needs React's own useState imports this one under another name, rather than either
// being renamed: the two are unrelated and both names are the right one where they are used.
//
export function useState(): IConfig {
    const context = useContext(StateContext);
    if (!context) {
        throw new Error(`StateContext is not set! Add StateContextProvider to the component tree.`);
    }
    return context;
}
