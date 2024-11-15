import React, { useEffect, useRef, useState } from "react";
import { IGalleryItem, IGalleryRow } from "../lib/gallery-item";
import { useGallery } from "../context/gallery-context";
import { GetHeadingsFn, IGalleryLayout, computePartialLayout } from "../lib/create-layout";
import { GalleryScrollbar } from "./gallery-scrollbar";
import { GalleryImage } from "./gallery-image";
import { debounce, throttle } from "lodash";

export type ItemClickFn = ((item: IGalleryItem) => void);

//
// Renders a row of items in the gallery.
//
function renderRow(row: IGalleryRow, rowIndex: number, isScrolling: boolean, onItemClick: ItemClickFn | undefined) {
    if (row.type === "heading") {
        //
        // Renders a heading row.
        //
        const heading = row.headings.join(" ");
        return (
            <div 
                key={heading}
                style={{
                    fontSize: "0.9rem",
                    color: "rgb(60,64,67)",
                    fontWeight: 600,
                    lineHeight: "1.25rem",
                    letterSpacing: ".0178571429em",
                    padding: "1em",
                    position: "absolute",
                    top: `${row.offsetY}px`,
                    height: `${row.height}px`,
                }}
                >
                {heading}
            </div>
        );
    }

    //
    // Renders a row of gallery items.
    //
    return (
        <div
            key={rowIndex}
            >
            {row.items.map((item, index) => {
                return (
                    <GalleryImage
                        key={item._id}
                        isScrolling={isScrolling}
                        item={item}
                        onClick={() => {
                            if (onItemClick) {
                                onItemClick(item);
                            }
                        }}
                        x={item.offsetX!}
                        y={row.offsetY}
                        width={item.thumbWidth!}
                        height={item.thumbHeight!}
                        />
                );
            })}
        </div>        
    );
}

//
// Represents a range of rows in the gallery.
//
interface IRange {
    //
    // The index of the first row to render.
    //
    startIndex: number;

    // 
    // The index of the last row to render.
    //
    endIndex: number;
}

//
// Determines the range of visible items.
//
function findVisibleRange(galleryLayout: IGalleryLayout | undefined, scrollTop: number, contentHeight: number): IRange | undefined {
    if (!galleryLayout) {
        return undefined;
    }

    const buffer = 2; // Number of items to render outside the viewport, above and below
    const startIndex = Math.max(0, galleryLayout.rows.findIndex(row => row.offsetY >= scrollTop) - buffer);

    let endIndex = startIndex+1;
    while (endIndex < galleryLayout.rows.length) {
        const row = galleryLayout.rows[endIndex];
        if (row.offsetY - scrollTop > contentHeight) {
            break;
        }
        endIndex++;
    }

    endIndex = Math.min(galleryLayout.rows.length-1, endIndex + buffer);

    return {
        startIndex,
        endIndex,
    };      
}    

//
// Renders rows in the visible range.
//
function renderVisibleRange(
    galleryLayout: IGalleryLayout | undefined, 
    scrollTop: number, 
    contentHeight: number | undefined, 
    isScrolling: boolean, 
    onItemClick: ItemClickFn | undefined
        ) {
    if (!contentHeight || !galleryLayout) {
        return [];
    }

    const range = findVisibleRange(galleryLayout, scrollTop, contentHeight);
    if (!range) {
        return [];
    }

    const renderedRows: JSX.Element[] = [];

    //
    //  Render rows in the visible range.
    //
    for (let rowIndex = range.startIndex; rowIndex <= range.endIndex; rowIndex++) {
        const row = galleryLayout.rows[rowIndex];

        //
        // Only render rows actually on screen.
        //
        renderedRows.push(renderRow(row, rowIndex, isScrolling, onItemClick));
    }

    return renderedRows;
}

export interface IGalleryLayoutProps { 
    //
    // The width of the gallery.
    //
	galleryWidth: number;

    //
    // The target height for rows in the gallery.
    //
	targetRowHeight: number;

    //
    // Event raised when an item in the gallery has been clicked.
    //
    onItemClick: ItemClickFn | undefined;

    //
    // Gets headings from a gallery item.
    //
    getHeadings?: GetHeadingsFn;
}

//
// Responsible for row-based gallery layout.
//
export function GalleryLayout({
	galleryWidth = 600, 
	targetRowHeight = 150, 
    onItemClick = undefined,
    getHeadings,
    }: IGalleryLayoutProps) {

    const { getSearchedItems, onReset, onNewItems, onItemsDeleted, searchText } = useGallery();
    
    const containerRef = useRef<HTMLDivElement>(null);
    const [ scrollTop, setScrollTop ] = useState(0);

    const isScrolling = useRef(false);
    const workingScrollTop = useRef(0);
    const scrollDistance = useRef(0);
    
    //
    // The layout of the gallery.
    //
    const [layout, setLayout] = useState<IGalleryLayout | undefined>(undefined);

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

    useEffect(() => {
        if (galleryWidth > 0) {
            //
            // Incrementally builds the layout as items are loaded.
            //
            const subscription1 = onNewItems.subscribe(items => {
                setLayout(prevLayout => computePartialLayout(prevLayout, items, galleryWidth, targetRowHeight, getHeadings));
            });

            //
            // Rebuilds the layout when items are deleted.
            //
            const subscription2 = onItemsDeleted.subscribe(() => {
                setLayout(computePartialLayout(undefined, getSearchedItems(), galleryWidth, targetRowHeight, getHeadings));        
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
        setLayout(computePartialLayout(undefined, getSearchedItems(), galleryWidth, targetRowHeight, getHeadings));        
    }, [galleryWidth, targetRowHeight, searchText]);

    //
    // Handles scrolling.
    //
    useEffect(() => {
        if (!containerRef.current) {
            return;
        }

        const container = containerRef.current;

        const onScrollDone = debounce(() => {
            isScrolling.current = false
            workingScrollTop.current = 0;
            scrollDistance.current = 0;
            setScrollTop(container.scrollTop-1); // The -1 is to force a re-render.
        }, 200);

        const onScrollThrottled = throttle(() => {
            scrollDistance.current = Math.abs(container.scrollTop - workingScrollTop.current);
            workingScrollTop.current = container.scrollTop;
            setScrollTop(container.scrollTop);
            onScrollDone();            
        }, 10);

        function onScroll() {
            if (!isScrolling.current) {
                // Started scrolling.
                isScrolling.current = true;
                workingScrollTop.current = container.scrollTop;
            }

            onScrollThrottled();
        }
       
        container.addEventListener('scroll', onScroll);
    
        return () => {
            container.removeEventListener('scroll', onScroll);
        };
    }, []);

    return (
        <div
            className="gallery-scroller"
            ref={containerRef}
            style={{
                overflowX: "hidden",
                height: "100%",
                position: "relative",
            }}
            >
            <div
                style={{
                    width: `${galleryWidth}px`,
                    height: `${layout?.galleryHeight}px`,
                    overflowX: "hidden",
                    position: "relative",
                }}
                >
                {renderVisibleRange(layout, scrollTop, containerRef.current?.clientHeight, scrollDistance.current > 10, onItemClick)}
            </div>

            {layout
                && <GalleryScrollbar
                    galleryContainerHeight={containerRef.current?.clientHeight || 0}
                    galleryLayout={layout}
                    scrollTop={scrollTop}
                    scrollTo={scrollPosition => {
                        containerRef.current!.scrollTo({ top: scrollPosition, behavior: "instant" } as any); //TODO: Remove the "as any" when the types are updated in TS 5.1+.
                    }}
                    />
            }

        </div>
    );
}
