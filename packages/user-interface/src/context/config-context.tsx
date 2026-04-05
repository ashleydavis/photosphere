import React, { ReactNode, createContext, useContext } from "react";

//
// High-level config interface used throughout the UI.
// All methods are generic — no configuration keys are defined here.
//
export interface IConfig {
    //
    // Gets a stored value by key. Returns undefined if the key has not been set.
    //
    get<T>(key: string): Promise<T | undefined>;

    //
    // Sets a value by key, replacing any existing value.
    //
    set<T>(key: string, value: T): Promise<void>;

    //
    // Prepends an item to the array stored at key, removing any existing duplicate.
    // If maxItems is provided, the list is trimmed to that length.
    //
    add<T>(key: string, item: T, maxItems?: number): Promise<void>;

    //
    // Removes an item from the array stored at key.
    //
    remove<T>(key: string, item: T): Promise<void>;

    //
    // Removes the value stored at key.
    //
    clear(key: string): Promise<void>;
}

//
// Builds an IConfig from a low-level get/set pair provided by a platform.
// The add/remove/clear operations are implemented here in terms of get/set.
//
export function createConfig(
    getRaw: (key: string) => Promise<unknown>,
    setRaw: (key: string, value: unknown) => Promise<void>
): IConfig {
    return {
        async get<T>(key: string): Promise<T | undefined> {
            return getRaw(key) as Promise<T | undefined>;
        },

        async set<T>(key: string, value: T): Promise<void> {
            await setRaw(key, value);
        },

        async add<T>(key: string, item: T, maxItems?: number): Promise<void> {
            const current = (await getRaw(key) as T[] | undefined) || [];
            const deduped = [item, ...current.filter(existing => existing !== item)];
            await setRaw(key, maxItems !== undefined ? deduped.slice(0, maxItems) : deduped);
        },

        async remove<T>(key: string, item: T): Promise<void> {
            const current = (await getRaw(key) as T[] | undefined) || [];
            await setRaw(key, current.filter(existing => existing !== item));
        },

        async clear(key: string): Promise<void> {
            await setRaw(key, undefined);
        },
    };
}

const ConfigContext = createContext<IConfig | undefined>(undefined);

export interface IConfigContextProviderProps {
    //
    // The IConfig implementation to provide to the component tree.
    //
    value: IConfig;

    //
    // Child components that will have access to the config.
    //
    children: ReactNode | ReactNode[];
}

//
// Provides an IConfig implementation to the component tree.
//
export function ConfigContextProvider({ value, children }: IConfigContextProviderProps) {
    return (
        <ConfigContext.Provider value={value}>
            {children}
        </ConfigContext.Provider>
    );
}

//
// Returns the config from context. Must be used within a ConfigContextProvider.
//
export function useConfig(): IConfig {
    const context = useContext(ConfigContext);
    if (!context) {
        throw new Error(`ConfigContext is not set! Add ConfigContextProvider to the component tree.`);
    }
    return context;
}
