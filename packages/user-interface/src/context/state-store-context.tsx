//
// The React context that hands the state store to the component tree.
//
import React, { ReactNode, createContext, useContext } from "react";
import type { IConfig } from "./config-store-context";

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
// the file underneath: each platform backs this context with state.yaml and the config store context
// with config.yaml.
//
const StateStoreContext = createContext<IConfig | undefined>(undefined);

//
// Props for the state store provider.
//
export interface IStateStoreContextProviderProps {
    //
    // The store to provide to the component tree.
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
export function StateStoreContextProvider({ value, children }: IStateStoreContextProviderProps) {
    return (
        <StateStoreContext.Provider value={value}>
            {children}
        </StateStoreContext.Provider>
    );
}

//
// Returns the state store from context. Must be used within a StateStoreContextProvider.
//
export function useStateStore(): IConfig {
    const context = useContext(StateStoreContext);
    if (!context) {
        throw new Error(`StateStoreContext is not set! Add StateStoreContextProvider to the component tree.`);
    }
    return context;
}
