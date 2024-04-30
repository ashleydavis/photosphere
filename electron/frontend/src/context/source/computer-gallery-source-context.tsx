//
// Provides a source of assets for the gallery from the local computer.
//

import React, { createContext, ReactNode, useContext, useState } from "react";
import { IGallerySource } from "user-interface/src/context/source/gallery-source";
import { useScan } from "../scan-context";

export interface IComputerGallerySourceContext extends IGallerySource {
}

const ComputerGallerySourceContext = createContext<IComputerGallerySourceContext | undefined>(undefined);

export interface IComputerGallerySourceContextProviderProps {
    children: ReactNode | ReactNode[];
}

export function ComputerGallerySourceContextProvider({ children }: IComputerGallerySourceContextProviderProps) {

    //
    // The interface to file system scanning.
    //
    const { assets } = useScan();

    //
    // Loads data for an asset.
    //
    function loadAsset(assetId: string, type: string, onLoaded: (objectURL: string) => void): void {
        //TODO: 
    }

    //
    // Unloads data for an asset.
    //
    function unloadAsset(assetId: string): void {
        //TODO:
    }

    const value: IComputerGallerySourceContext = {
        assets,
        loadAsset,
        unloadAsset,
    };
    
    return (
        <ComputerGallerySourceContext.Provider value={value} >
            {children}
        </ComputerGallerySourceContext.Provider>
    );
}

//
// Use the "computer source" in a component.
//
export function useComputerGallerySource(): IComputerGallerySourceContext {
    const context = useContext(ComputerGallerySourceContext);
    if (!context) {
        throw new Error(`"Computer source" context is not set! Add ComputerGallerySourceContextProvider to the component tree.`);
    }
    return context;
}

