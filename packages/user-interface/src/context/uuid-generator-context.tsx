import React, { ReactNode, createContext, useContext } from "react";
import type { IUuidGenerator } from "utils";

//
// Holds the process-wide uuid generator so any component can read it without
// going through `useAssetDatabase` (the generator is not an asset-database concern;
// it just happens to be needed by the queue plumbing). Tests inject a deterministic
// `TestUuidGenerator` here; production injects `RandomUuidGenerator`.
//
const UuidGeneratorContext = createContext<IUuidGenerator | undefined>(undefined);

export interface IUuidGeneratorProviderProps {
    // The uuid generator to expose to descendants.
    value: IUuidGenerator;

    // Children that may consume the generator via useUuidGenerator().
    children: ReactNode | ReactNode[];
}

//
// Provides the uuid generator to its descendants.
//
export function UuidGeneratorProvider({ value, children }: IUuidGeneratorProviderProps) {
    return (
        <UuidGeneratorContext.Provider value={value}>
            {children}
        </UuidGeneratorContext.Provider>
    );
}

//
// Returns the uuid generator from the surrounding UuidGeneratorProvider.
// Throws if no provider is in the tree.
//
export function useUuidGenerator(): IUuidGenerator {
    const generator = useContext(UuidGeneratorContext);
    if (!generator) {
        throw new Error("UuidGeneratorContext is not set! Add UuidGeneratorProvider to the component tree.");
    }
    return generator;
}
