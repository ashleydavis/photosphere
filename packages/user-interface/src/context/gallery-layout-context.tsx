import React, { createContext, ReactNode, useContext, useEffect, useRef, useState } from "react";
import { computePartialLayout, IGalleryLayout } from "../lib/create-layout";
import { useGallery } from "./gallery-context";
import { IGalleryItem } from "../lib/gallery-item";
import dayjs from "dayjs";
import { isArray } from "lodash";

//
// Specifies how to group a gallery itemm.
// 
interface IGroupBy {
    //
    // Selects the field to sort by.
    //
    sortKey(asset: IGalleryItem): any;

    //
    // Gets the group of the asset.
    //
    group(asset: IGalleryItem): string[];

    //
    // Gets the heading for the group of the asset.
    //
    heading(group: string[]): string;
}

//
// Selects the grouping for the gallery.
//
const groupingMap: { [key: string]: IGroupBy } = {
    date: {
        // Sorts the photos by date.
        sortKey: asset => asset.photoDate ? dayjs(asset.photoDate).toDate() : undefined,

        // Groups the photos by year and month.
        group: asset => asset.photoDate
            ? [
                dayjs(asset.photoDate).format("YYYY"),
                dayjs(asset.photoDate).format("MMMM"),
            ]
            : [ "Undated" ],

        // Formats the group heading.
        heading: (group: string[]) => group.slice().reverse().join(" "),
    },
    location: {
        // Sorts the photos by location.
        sortKey: asset => asset.location
            ? asset.location.split(",").map(s => s.trim()).reverse().slice(0, 3)
            : undefined,

        // Groups the photos by location
        group: asset => asset.location
            ? asset.location.split(",").map(s => s.trim()).reverse().slice(0, 3)
            : [ "Location unknown" ],

        // Formats the group heading.
        heading: (group: string[]) => group.slice().reverse().join(", "),
    },
}

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

    //
    // The way the gallery is grouped.
    //
    groupBy: string;

    //
    // Sets the way the gallery is grouped.
    //
    setGroupBy(groupBy: string): void;
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
    const [targetRowHeight, setTargetRowHeight] = useState(80);
    
    //
    // The current layout of the gallery.
    //
    const [layout, setLayout] = useState<IGalleryLayout | undefined>(undefined);

    //
    // The way the gallery is grouped.
    //
    const [groupBy, setGroupBy] = useState<string>("date");

    const { getSearchedItems, onReset, onNewItems, onItemsDeleted, searchText } = useGallery();

    //
    // Items after sorting.
    //
    const [ sortedItems, setSortedItems ] = useState<IGalleryItem[]>([]);

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
    // This used to do a partial layout as new assets came in, but that can't work now that sorting/grouping
    // can be changed in the UI.
    // Simplest thing is to just rebuild the layout from scratch when anything changes.
    //
    function rebuildLayout() {
        if (galleryWidth === 0) {
            return;
        }
        const grouping = groupingMap[groupBy];
        if (!grouping) {
            throw new Error(`Unknown groupBy value: ${groupBy}`);
        }
        const sortedItems = getSearchedItems().slice();
        sortedItems.sort((a, b) => {
            const sortA = grouping.sortKey(a);
            const sortB = grouping.sortKey(b);
            if (sortA === undefined) {
                if (sortB === undefined) {
                    return 0; // Equal.
                }
                else {
                    return 1; // a has no sort value, so it comes last.
                }
            }
            else if (sortB === undefined) {
                return -1; // b has no sort value, so it comes last.
            }

            if (isArray(sortA) && isArray(sortB)) {
                for (let i = 0; i < Math.min(sortA.length, sortB.length); i++) {
                    if (sortA[i] < sortB[i]) {
                        return -1; // a comes before b
                    }
    
                    if (sortA[i] > sortB[i]) {
                        return 1;  // a comes after b
                    }
                }
                  
                // If all compared elements are equal, sort by length
                return sortA.length - sortB.length;
            }
            else {
                if (sortA < sortB) {
                    return 1; // a comes after b.
                }
                else if (sortA > sortB) {
                    return -1; // a comes before b.
                }
                else {
                    return 0; // a and b are equal.
                }
            }
        });
        setLayout(computePartialLayout(undefined, sortedItems, galleryWidth, targetRowHeight, grouping.group, grouping.heading));
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

    }, [galleryWidth, targetRowHeight, searchText, groupBy]);


    //
    // Old code that built the layout incrementally as items were added.
    // This doesn't work so well now that sorting/grouping can change in the UI.
    //
    // useEffect(() => {
    //     if (galleryWidth > 0) {
    //         //
    //         // Incrementally builds the layout as items are loaded.
    //         //
    //         const subscription1 = onNewItems.subscribe(items => {
    //             const grouping = groupingMap[groupBy];
    //             setSortedItems(sortedItems.concat(items));]
    //             setLayout(prevLayout => computePartialLayout(prevLayout, items, galleryWidth, targetRowHeight, grouping.group, grouping.heading));
    //         });

    //         //
    //         // Rebuilds the layout when items are deleted.
    //         //
    //         const subscription2 = onItemsDeleted.subscribe(() => {
    //             const grouping = groupingMap[groupBy];
    //             setLayout(computePartialLayout(undefined, getSearchedItems(), galleryWidth, targetRowHeight, grouping.group, grouping.heading));
    //         });

    //         return () => {
    //             subscription1.unsubscribe();
    //             subscription2.unsubscribe();
    //         };
    //     }
    // }, [galleryWidth]);

    const value: IGalleryLayoutContext = {
        galleryWidth,
        setGalleryWidth,
        targetRowHeight,
        setTargetRowHeight,
        layout,
        scrollTo,
        setScrollToHandler,
        groupBy,
        setGroupBy,
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

