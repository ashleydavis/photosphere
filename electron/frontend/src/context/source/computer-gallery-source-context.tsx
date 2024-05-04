//
// Provides a source of assets for the gallery from the local computer.
//

import React, { createContext, ReactNode, useContext, useState } from "react";
import { IGallerySource } from "user-interface/src/context/source/gallery-source";
import { useScan } from "../scan-context";
import { IGalleryItem } from "user-interface";

//
// Use the "computer source" in a component.
//
export function useComputerGallerySource(): IGallerySource {

    //
    // The interface to file system scanning.
    //
    const { assets } = useScan();

    //
    // Retreives assets from the source.
    //
    async function getAssets(): Promise<IGalleryItem[]> {
        //TODO:
        return [];
    }

    //
    // Loads data for an asset.
    //
    async function loadAsset(assetId: string, type: string): Promise<string | undefined> {
        //TODO: 
        return undefined;
    }

    //
    // Unloads data for an asset.
    //
    function unloadAsset(assetId: string): void {
        //TODO:
    }

    return {
        getAssets,
        loadAsset,
        unloadAsset,
    };
}
