import React, { createContext, ReactNode, useContext, useEffect, useRef, useState } from "react";
import { computePartialLayout, deleteFromLayout, IGalleryLayout } from "../lib/create-layout";
import { useGallery } from "./gallery-context";
import { IGalleryItem } from "../lib/gallery-item";

//
// Manages the layout of the gallery.
//
export interface IGalleryLayoutContext {
    //
    // The width of the gallery.
    //
    galleryWidth: number;

    //
    // Sets the width of the gallery.
    //
    setGalleryWidth: (width: number) => void;

    //
    // The target row height of the gallery.
    //
    targetRowHeight: number;

    //
    // Sets the target row height of the gallery.
    //
    setTargetRowHeight: (height: number) => void;

    //
    // The current layout of the gallery.
    //
    layout?: IGalleryLayout;

    //
    // Scrolls the gallery to the specified location.
    //
    scrollTo(scrollTop: number): void;

    //
    // Sets a handler to scroll the gallery.
    //
    setScrollToHandler(handler: (scrollTop: number) => void): void;
}

const GalleryLayoutContext = createContext<IGalleryLayoutContext | undefined>(undefined);

export interface IGalleryLayoutContextProviderProps {
    children: ReactNode | ReactNode[];
}

//
// Manages the layout of the gallery.
//
export function GalleryLayoutContextProvider({ children }: IGalleryLayoutContextProviderProps) {

    //
    // The width of the gallery.
    //
    const [galleryWidth, setGalleryWidth] = useState<number>(0);

    //
    // The target row height of the gallery.
    //
    const savedHeight = localStorage.getItem("gallery-row-height");
    const [targetRowHeight, _setTargetRowHeight] = useState(savedHeight ? parseInt(savedHeight) : 80);
    
    //
    // The current layout of the gallery, stored in a ref so updates during incremental loading
    // do not trigger a React re-render on every batch. Renders are instead driven by setTime
    // at most once per animation frame.
    //
    const layoutRef = useRef<IGalleryLayout | undefined>(undefined);

    //
    // A simple counter used to trigger re-renders when the layout changes outside of
    // the incremental-loading path (e.g. rebuild, delete, update).
    //
    const [_time, setTime] = useState<number>(0);

    const { sortedItems, onReset, onNewItems, onItemsDeleted, onItemsUpdated, getItemById, searchText, sortBy, sorting } = useGallery();

    const scrollToHandler = useRef<(scrollTop: number) => void>();

    //
    // Maps assetId to its position in the layout for O(1) item replacement on update.
    //
    const layoutItemsIndex = useRef<Map<string, { rowIndex: number; itemIndex: number }>>(new Map());

    //
    // Scrolls the gallery to the specified location.
    //
    function scrollTo(scrollTop: number): void {
        if (scrollToHandler.current) {
            scrollToHandler.current(scrollTop);
        }
    }

    //
    // Sets a handler to scroll the gallery.
    //
    function setScrollToHandler(handler: (scrollTop: number) => void): void {
        scrollToHandler.current = handler;
    }

    //
    // Resets the gallery layout as necessary in preparation for incremental loading.
    //
    useEffect(() => {
        const subscription = onReset.subscribe(() => {
            layoutRef.current = undefined;
            setTime(Date.now());
        });
        return () => {
            subscription.unsubscribe();
        };
    }, []);


    //
    // Brute force layout rebuid.
    // This used to do a partial layout as new assets came in, but that can't work now that sorting
    // can be changed in the UI.
    // Simplest thing is to just rebuild the layout from scratch when anything changes.
    //
    function rebuildLayout() {
        if (galleryWidth === 0) {
            return;
        }
        const _sorting = sorting();
        const newLayout = computePartialLayout(undefined, sortedItems(), galleryWidth, targetRowHeight, _sorting.group, _sorting.heading);

        const newIndex = new Map<string, { rowIndex: number; itemIndex: number }>();
        for (let rowIndex = 0; rowIndex < newLayout.rows.length; rowIndex++) {
            const row = newLayout.rows[rowIndex];
            for (let itemIndex = 0; itemIndex < row.items.length; itemIndex++) {
                newIndex.set(row.items[itemIndex]._id, { rowIndex, itemIndex });
            }
        }
        layoutItemsIndex.current = newIndex;

        layoutRef.current = newLayout;
        setTime(Date.now());
    }

    useEffect(() => {
        rebuildLayout();

        if (galleryWidth > 0) {
            //
            // Incrementally appends new items to the existing layout.
            //
            const newItemsSubscription = onNewItems.subscribe(newItems => {
                // Compute layout into the ref synchronously — no React state update yet.
                const _sorting = sorting();
                const startingRowIndex = (layoutRef.current && layoutRef.current.rows.length > 0) ? layoutRef.current.rows.length - 1 : 0;
                layoutRef.current = computePartialLayout(layoutRef.current, newItems, galleryWidth, targetRowHeight, _sorting.group, _sorting.heading);
                for (let rowIndex = startingRowIndex; rowIndex < layoutRef.current.rows.length; rowIndex++) {
                    const row = layoutRef.current.rows[rowIndex];
                    for (let itemIndex = 0; itemIndex < row.items.length; itemIndex++) {
                        layoutItemsIndex.current.set(row.items[itemIndex]._id, { rowIndex, itemIndex });
                    }
                }
                // No state update here. The rAF-throttled setTime in gallery-context cascades
                // through (GalleryLayoutContextProvider re-renders as a consumer of useGallery()),
                // which picks up the latest layoutRef.current at that point.
            });

            //
            // Incrementally reflows the layout from the earliest affected row when items are deleted.
            //
            const deletedItemsSubscription = onItemsDeleted.subscribe(({ assetIds }) => {
                if (!layoutRef.current) {
                    return;
                }
                const _sorting = sorting();
                const newLayout = deleteFromLayout(layoutRef.current, assetIds, galleryWidth, targetRowHeight, _sorting.group, _sorting.heading);
                if (newLayout === layoutRef.current) {
                    return;
                }
                const newIndex = new Map<string, { rowIndex: number; itemIndex: number }>();
                for (let rowIndex = 0; rowIndex < newLayout.rows.length; rowIndex++) {
                    const row = newLayout.rows[rowIndex];
                    for (let itemIndex = 0; itemIndex < row.items.length; itemIndex++) {
                        newIndex.set(row.items[itemIndex]._id, { rowIndex, itemIndex });
                    }
                }
                layoutItemsIndex.current = newIndex;
                layoutRef.current = newLayout;
                setTime(Date.now());
            });

            //
            // Updates item references in-place when items are updated, without rebuilding the layout.
            //
            const updatedItemsSubscription = onItemsUpdated.subscribe(({ assetIds }) => {
                if (!layoutRef.current) {
                    return;
                }
                const newRows = layoutRef.current.rows.slice();
                let changed = false;
                for (const assetId of assetIds) {
                    const position = layoutItemsIndex.current.get(assetId);
                    if (position === undefined) {
                        continue;
                    }
                    const updatedItem = getItemById(assetId);
                    if (updatedItem === undefined) {
                        continue;
                    }
                    const row = newRows[position.rowIndex];
                    const newItems = row.items.slice() as IGalleryItem[];
                    newItems[position.itemIndex] = updatedItem;
                    newRows[position.rowIndex] = { ...row, items: newItems };
                    changed = true;
                }
                if (changed) {
                    layoutRef.current = { ...layoutRef.current, rows: newRows };
                    setTime(Date.now());
                }
            });

            return () => {
                newItemsSubscription.unsubscribe();
                deletedItemsSubscription.unsubscribe();
                updatedItemsSubscription.unsubscribe();
            };
        }

    }, [galleryWidth, targetRowHeight, searchText, sortBy]);

    const setTargetRowHeight = (height: number) => {
        _setTargetRowHeight(height);
        localStorage.setItem("gallery-row-height", height.toString());
    };

    const value: IGalleryLayoutContext = {
        galleryWidth,
        setGalleryWidth,
        targetRowHeight,
        setTargetRowHeight,
        layout: layoutRef.current,
        scrollTo,
        setScrollToHandler,
    };

    return (
        <GalleryLayoutContext.Provider value={value} >
            {children}
        </GalleryLayoutContext.Provider>
    );
}

//
// Use the gallery layout in a component.
//
export function useGalleryLayout(): IGalleryLayoutContext {
    const context = useContext(GalleryLayoutContext);
    if (!context) {
        throw new Error(`Gallery layout context is not set! Add GalleryLayoutContextProvider to the component tree.`);
    }
    return context;
}

