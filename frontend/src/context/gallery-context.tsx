import React, { createContext, ReactNode, useContext, useState } from "react";
import { IGalleryItem } from "../lib/gallery-item";
import { useApi } from "./api-context";

const NUM_ASSETS_PER_PAGE = 100;

export interface IGalleryContext {

    //
    // The assets currently loaded.
    //
    assets: IGalleryItem[];

    //
    // The number of pages loaded.
    //
    pagesLoaded: number;

    //
    // Set to true if there are more assets that can be loaded.
    //
    haveMoreAssets: boolean;

    //
    // Adds an asset to the gallery.
    //
    addAsset(asset: IGalleryItem): void;

    //
    // Sets the assets currently loaded.
    //
    setAssets(assets: IGalleryItem[]): void;

    //
    // Loads the requested page of the gallery.
    //
    loadPage(pageNumber: number): Promise<void>;

    //
    // Resets the gallery to the initial condition.
    //
    reset(): Promise<void>;
}

const GalleryContext = createContext<IGalleryContext | undefined>(undefined);

export interface IProps {
    children: ReactNode | ReactNode[];
}

export function GalleryContextProvider({ children }: IProps) {

    //
    // Interface to the backend.
    //
    const api = useApi();

    //
    // Assets that have been loaded from the backend.
    //
    const [ assets, setAssets ] = useState<IGalleryItem[]>([]);

    //
    // Records the number of pages loaded so far.
    //
    const [ pagesLoaded, setPagesLoaded ] = useState<number>(0);

    //
    // Set to true when there's more assets to load.
    //
    const [ haveMoreAssets, setHaveMoreAssets ] = useState<boolean>(false);

    //
    // Adds an asset to the gallery.
    //
    function addAsset(asset: IGalleryItem): void {
        setAssets([ asset, ...assets ]);
    }

    //
    // Loads the requested page of the gallery.
    // Note: 1-based page numbers.
    //
    async function loadPage(pageNumber: number): Promise<void> {
        
        console.log(`Loading page ${pageNumber}`);

        if (pageNumber <= pagesLoaded) {
            console.log(`Page ${pageNumber} is already loaded`);
            return;
        }

        const skip = (pageNumber-1) * NUM_ASSETS_PER_PAGE;
        const limit = NUM_ASSETS_PER_PAGE;
        setPagesLoaded(pageNumber);

        console.log(`Skipping ${skip}`)
        console.log(`Limit ${limit}`)
        
        const newAssets = await api.getAssets(skip, limit);
        if (newAssets.length === 0) {
            //
            // Ran out of items to load!
            //
            setHaveMoreAssets(false);
            console.log(`Finished loading assets.`);
            return;
        }

        //
        // Keep a copy of newly loaded assets.
        //
        setAssets(assets.concat(newAssets));
        setHaveMoreAssets(true);
    }

    //
    // Resets the gallery to the initial condition.
    // The current search text remains unchanged.
    //
    async function reset(): Promise<void> {
        setPagesLoaded(0);
        setAssets([]);
        setHaveMoreAssets(true);
    }    

    const value: IGalleryContext = {
        assets,
        pagesLoaded,
        haveMoreAssets,
        addAsset,
        setAssets,
        loadPage,
        reset,
    };
    
    return (
        <GalleryContext.Provider value={value} >
            {children}
        </GalleryContext.Provider>
    );
}

//
// Use the gallery context in a component.
//
export function useGallery(): IGalleryContext {
    const context = useContext(GalleryContext);
    if (!context) {
        throw new Error(`Gallery context is not set! Add GalleryContextProvider to the component tree.`);
    }
    return context;
}

