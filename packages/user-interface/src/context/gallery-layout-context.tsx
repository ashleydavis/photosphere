import React, { createContext, ReactNode, useContext, useEffect, useRef, useState } from "react";
import { computePartialLayout, IGalleryLayout } from "../lib/create-layout";
import { useGallery } from "./gallery-context";
import { IGalleryItem } from "../lib/gallery-item";
import dayjs from "dayjs";

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
    const [targetRowHeight, setTargetRowHeight] = useState(150);
    
    //
    // The current layout of the gallery.
    //
    const [layout, setLayout] = useState<IGalleryLayout | undefined>(undefined);

    const { getSearchedItems, onReset, onNewItems, onItemsDeleted, searchText } = useGallery();

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

    function getGroup(item: IGalleryItem) {
        return item.photoDate
            ? [
                dayjs(item.photoDate).format("YYYY"),
                dayjs(item.photoDate).format("MMMM"),
            ]
            : ["Undated"];
    };

    function getHeading(group: string[]): string {
        const reversed = group.slice().reverse();
        return reversed.join(" ");
    };

    useEffect(() => {
        if (galleryWidth > 0) {
            //
            // Incrementally builds the layout as items are loaded.
            //
            const subscription1 = onNewItems.subscribe(items => {
                setLayout(prevLayout => computePartialLayout(prevLayout, items, galleryWidth, targetRowHeight, getGroup, getHeading));
            });

            //
            // Rebuilds the layout when items are deleted.
            //
            const subscription2 = onItemsDeleted.subscribe(() => {
                setLayout(computePartialLayout(undefined, getSearchedItems(), galleryWidth, targetRowHeight, getGroup, getHeading));
            });

            return () => {
                subscription1.unsubscribe();
                subscription2.unsubscribe();
            };
        }
    }, [galleryWidth]);

    //
    // Rebuilds the gallery layout as necessary when important details have changed.
    //
    useEffect(() => {
        if (galleryWidth === 0) {
            return;
        }
        setLayout(computePartialLayout(undefined, getSearchedItems(), galleryWidth, targetRowHeight, getGroup, getHeading));
    }, [galleryWidth, targetRowHeight, searchText]);

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

