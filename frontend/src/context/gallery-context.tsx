import React, { createContext, ReactNode, useContext, useState } from "react";
import { IGalleryItem, ISelectedGalleryItem } from "../lib/gallery-item";
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

    //
    // The current search text.
    //
    searchText: string;

    //
    // Search for assets based on text input.
    //
    search(searchText: string): Promise<void>;

    //
    // Clears the current search.
    //
    clearSearch(): Promise<void>;

    //
    // Gets the previous asset, or undefined if none.
    //
    getPrev(selectedItem: ISelectedGalleryItem): ISelectedGalleryItem | undefined;

    //
    // Gets the next asset, or undefined if none.
    //
    getNext(selectedItem: ISelectedGalleryItem): ISelectedGalleryItem | undefined;

    //
    // The currently selected gallery item or undefined when no item is selected.
    //
    selectedItem: ISelectedGalleryItem | undefined
    
    //
    // Sets the selected gallery item.
    //
    setSelectedItem(selectedItem: ISelectedGalleryItem | undefined): void;

    //
    // Clears the currently selected gallery item.
    //
    clearSelectedItem(): void;
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
    // The current search that has been executed.
    //
    const [ searchText, setSearchText ] = useState<string>("");

    //
    // Records the number of pages loaded so far.
    //
    const [ pagesLoaded, setPagesLoaded ] = useState<number>(0);

    //
    // Set to true when there's more assets to load.
    //
    const [ haveMoreAssets, setHaveMoreAssets ] = useState<boolean>(false);

    //
    // The item in the gallery that is currently selected.
    //
    const [selectedItem, setSelectedItem] = useState<ISelectedGalleryItem | undefined>(undefined);

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
        
        const newAssets = await api.getAssets(searchText, skip, limit);
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
        clearSelectedItem();
    }    

    //
    // Sets the search text for finding assets.
    // Passing in empty string or undefined gets all assets.
    // This does a gallery reset when the search term has changed.
    //
    async function search(newSearchText: string): Promise<void> {
        
        console.log(`Setting asset search ${newSearchText}`);

        if (searchText === newSearchText) {
            //
            // No change.
            //
            return;
        }

        setSearchText(newSearchText);
        await reset();
    }

    //
    // Clears the current search.
    //
    async function clearSearch(): Promise<void> {
        await search("");
    }

    //
    // Gets the previous asset, or undefined if none.
    //
    function getPrev(selectedItem: ISelectedGalleryItem): ISelectedGalleryItem | undefined {
        if (selectedItem.index < 0) {
            return undefined;
        }

        if (selectedItem.index > 0) {
            const prevIndex = selectedItem.index-1;
            return {
                item: assets[prevIndex],
                index: prevIndex,
            };
        }
        else {
            return undefined;
        }
    }

    //
    // Gets the next asset, or undefined if none.
    //
    function getNext(selectedItem: ISelectedGalleryItem): ISelectedGalleryItem | undefined {
        
         if (selectedItem.index < 0) {
            return undefined;
        }

        if (selectedItem.index < assets.length-1) {
            const nextIndex = selectedItem.index + 1;
            return {
                item: assets[nextIndex],
                index: nextIndex,
            };
        }
        else {
            return undefined;
        }
    }

    //
    // Clears the currently selected gallery item.
    //
    function clearSelectedItem(): void {
        setSelectedItem(undefined);
    }

    const value: IGalleryContext = {
        assets,
        pagesLoaded,
        haveMoreAssets,
        addAsset,
        setAssets,
        loadPage,
        reset,
        searchText,
        search,
        clearSearch,
        getPrev,
        getNext,
        selectedItem,
        setSelectedItem,
        clearSelectedItem,
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

