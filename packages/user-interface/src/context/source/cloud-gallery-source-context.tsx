//
// Provides a source of assets for the gallery from the cloud.
//

import React, { createContext, ReactNode, useContext, useEffect, useState } from "React";
import { IGallerySourceContext } from "./gallery-source-context";
import { useApi } from "../api-context";
import { IGalleryItem } from "../../lib/gallery-item";
import { useSearch } from "../search-context";

const NUM_ASSETS_PER_PAGE = 100;

export interface ICloudGallerySourceContext extends IGallerySourceContext {
    //
    // Loads assets into the gallery.
    //
    loadAssets(): Promise<void>;

    //
    // Adds an asset to the gallery.
    //
    addAsset(asset: IGalleryItem): void;
}

const CloudGallerySourceContext = createContext<ICloudGallerySourceContext | undefined>(undefined);

export interface ICloudGallerySourceContextProviderProps {
    children: ReactNode | ReactNode[];
}

export function CloudGallerySourceContextProvider({ children }: ICloudGallerySourceContextProviderProps) {

    //
    // Interface to the backend.
    //
    const api = useApi();

    //
    // Gets search text.
    //
    const { searchText } = useSearch();
    
    //
    // Assets that have been loaded from the backend.
    //
    const [ assets, setAssets ] = useState<IGalleryItem[]>([]);

    //
    // Resets the gallery when the search text changes.
    //
    useEffect(() => {
        loadAssets();
    }, [searchText]);

    //
    // Loads assets into the gallery.
    //
    async function loadAssets(): Promise<void> {
        const newAssets = await api.getAssets(searchText);
        setAssets(newAssets);
    }

    //
    // Adds an asset to the gallery.
    //
    function addAsset(asset: IGalleryItem): void {
        setAssets([ asset, ...assets ]);
    }

    //
    // Updates the configuration of the asset.
    //
    function updateAsset(assetIndex: number, assetUpdate: Partial<IGalleryItem>): void {
        setAssets(prevAssets => {
            const newAsset = {
                ...prevAssets[assetIndex],
                ...assetUpdate,
            };
            return [
                ...prevAssets.slice(0, assetIndex),
                newAsset,
                ...prevAssets.slice(assetIndex + 1),
            ];        
        });
    }

    const value: ICloudGallerySourceContext = {
        loadAssets,
        assets,
        addAsset,
        updateAsset,
    };
    
    return (
        <CloudGallerySourceContext.Provider value={value} >
            {children}
        </CloudGallerySourceContext.Provider>
    );
}

//
// Use the "Cloud source" in a component.
//
export function useCloudGallerySource(): ICloudGallerySourceContext {
    const context = useContext(CloudGallerySourceContext);
    if (!context) {
        throw new Error(`"Cloud source" context is not set! Add CloudGallerySourceContextProvider to the component tree.`);
    }
    return context;
}

