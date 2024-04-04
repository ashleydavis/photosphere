//
// Provides a source of assets for the gallery from the local computer.
//

import React, { createContext, ReactNode, useContext, useState } from "react";
import { IGallerySourceContext } from "user-interface/src/context/source/gallery-source-context";
import { useScan } from "../scan-context";
import { IGalleryItem } from "user-interface";

export interface IComputerGallerySourceContext extends IGallerySourceContext {
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
    // Updates the configuration of the asset.
    //
    function updateAsset(assetIndex: number, assetUpdate: Partial<IGalleryItem>): void {
        //TODO: Want to store local data for an asset before it is uploaded.
    }

    const value: IComputerGallerySourceContext = {
        assets,
        updateAsset,
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

