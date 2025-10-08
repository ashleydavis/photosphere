import React, { createContext, ReactNode, useContext, useEffect, useRef, useState } from "react";
import { computePartialLayout, IGalleryLayout } from "../lib/create-layout";
import { useGallery } from "./gallery-context";

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
    // const savedHeight = localStorage.getItem("gallery-row-height");
    const defaultHeight = window.innerWidth < 768 ? 100 : 200;
    const [targetRowHeight, _setTargetRowHeight] = useState(defaultHeight);
    //
    // The current layout of the gallery.
    //
    const [layout, setLayout] = useState<IGalleryLayout | undefined>(undefined);

    const { sortedItems, onReset, onNewItems, onItemsDeleted, searchText, sortBy, sorting } = useGallery();

    const scrollToHandler = useRef<(scrollTop: number) => void>();

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
            setLayout(undefined);
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
        setLayout(computePartialLayout(undefined, sortedItems(), galleryWidth, targetRowHeight, _sorting.group, _sorting.heading));
    }

    useEffect(() => {
        rebuildLayout();

        if (galleryWidth > 0) {
            //
            // Rebuilds the layout when items are added.
            //
            const subscription1 = onNewItems.subscribe(items => {
                rebuildLayout();
            });

            //
            // Rebuilds the layout when items are deleted.
            //
            const subscription2 = onItemsDeleted.subscribe(() => {
                rebuildLayout();
            });

            return () => {
                subscription1.unsubscribe();
                subscription2.unsubscribe();
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
        layout,
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

