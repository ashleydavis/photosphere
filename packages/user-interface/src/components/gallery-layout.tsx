import React, { useEffect, useRef, useState } from "react";
import { IGalleryItem, IGalleryRow } from "../lib/gallery-item";
import { IGalleryLayout } from "../lib/create-layout";
import { GalleryScrollbar } from "./gallery-scrollbar";
import { GalleryImage } from "./gallery-image";
import { debounce, throttle } from "lodash";
import { Theme, useTheme } from "@mui/joy";
import { useGalleryLayout } from "../context/gallery-layout-context";

export type ItemClickFn = ((item: IGalleryItem) => void);

//
// Renders a row of items in the gallery.
//
function renderRow(row: IGalleryRow, rowIndex: number, isScrolling: boolean, theme: Theme, onItemClick: ItemClickFn | undefined) {
    if (row.type === "heading") {
        //
        // Renders a heading row.
        //
        return (
            <div 
                key={row.heading}
                style={{
                    fontSize: "0.9rem",
                    fontWeight: 600,
                    lineHeight: "1.25rem",
                    letterSpacing: ".0178571429em",
                    padding: "1em",
                    position: "sticky",
                    zIndex: 100,
                    top: `${row.offsetY}px`,
                    height: `${row.height}px`,
                }}
                >
                {row.heading}
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
    renderStartIndex: number;

    // 
    // The index of the last row to render.
    //
    renderEndIndex: number;

    //
    // The first row that's actually in the view port.
    //
    visibleStartIndex: number;

    //
    // The last row that's actually in the view port.
    //
    visibleEndIndex: number;
}

//
// Does a binary search to find the first row that's visible.
//
function findVisibleStartIndex(galleryLayout: IGalleryLayout | undefined, scrollTop: number): number {
    if (!galleryLayout) {
        return 0;
    }

    let low = 0;
    let high = galleryLayout.rows.length - 1;

    while (low < high) {
        const mid = Math.floor((low + high) / 2);
        const row = galleryLayout.rows[mid];

        if (row.offsetY < scrollTop) {
            low = mid + 1;
        }
        else {
            high = mid;
        }
    }

    return low;
}

//
// Determines the range of visible items.
//
function findVisibleRange(galleryLayout: IGalleryLayout | undefined, scrollTop: number, contentHeight: number): IRange | undefined {
    if (!galleryLayout) {
        return undefined;
    }

    const buffer = 2; // Number of items to render outside the viewport, above and below
    const visibleStartIndex = findVisibleStartIndex(galleryLayout, scrollTop);
    const renderStartIndex = Math.max(0, visibleStartIndex - buffer);

    let endIndex = visibleStartIndex+1;
    while (endIndex < galleryLayout.rows.length) {
        const row = galleryLayout.rows[endIndex];
        if (row.offsetY - scrollTop > contentHeight) {
            break;
        }
        endIndex++;
    }

    const visibleEndIndex = Math.min(galleryLayout.rows.length-1, endIndex);
    const renderEndIndex = Math.min(galleryLayout.rows.length-1, endIndex + buffer);

    return {
        renderStartIndex,
        renderEndIndex,
        visibleStartIndex,
        visibleEndIndex,
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
    theme: Theme,
    onItemClick: ItemClickFn | undefined
        ): {
            curHeadingRow?: IGalleryRow,
            rows: JSX.Element[],
        }
        {
    if (!contentHeight || !galleryLayout || galleryLayout.rows.length === 0) {
        return {
            rows: [],
        };
    }

    const range = findVisibleRange(galleryLayout, scrollTop, contentHeight);
    if (!range) {
        return {
            rows: [],
        };
    }

    let curHeadingRow: IGalleryRow | undefined;
    
    //
    // Search backward to find the latest heading.
    //
    for (let rowIndex = range.visibleStartIndex-1; rowIndex >= 0; rowIndex--) {        
        const row = galleryLayout.rows[rowIndex];
        if (row.type === "heading") {
            curHeadingRow = row;
            break;
        }
    }

    if (curHeadingRow) {
        //
        // Does the current heading overlap with the next heading?
        //
        for (let rowIndex = range.visibleStartIndex; rowIndex <= range.visibleEndIndex; rowIndex++) {
            const row = galleryLayout.rows[rowIndex];
            if (row.type === "heading") {
                if (row.offsetY < scrollTop + curHeadingRow.height) {
                    //
                    // Clear the current heading so it doesn't overlap with the next one.
                    //
                    curHeadingRow = undefined;
                }
                break;
            }
        }
    }   

    const rows: JSX.Element[] = [];

    //
    //  Render rows in the visible range.
    //
    for (let rowIndex = range.renderStartIndex; rowIndex <= range.renderEndIndex; rowIndex++) {
        const row = galleryLayout.rows[rowIndex];

        //
        // Only render rows actually on screen.
        //
        rows.push(renderRow(row, rowIndex, isScrolling, theme, onItemClick));
    }

    return {
        curHeadingRow,
        rows,
    };
}

export interface IGalleryLayoutProps {
    //
    // Event raised when an item in the gallery has been clicked.
    //
    onItemClick: ItemClickFn | undefined;
}

//
// Responsible for row-based gallery layout.
//
export function GalleryLayout({ onItemClick }: IGalleryLayoutProps) {

    const { galleryWidth, layout, setScrollToHandler } = useGalleryLayout();

    //
    // The scroll position of the gallery.
    //
    const [ scrollTop, setScrollTop ] = useState(0);

    const containerRef = useRef<HTMLDivElement>(null);  

    const isScrolling = useRef(false);
    const workingScrollTop = useRef(0);
    const scrollDistance = useRef(0);

    const theme = useTheme();

    //
    // Handles scrolling.
    //
    useEffect(() => {
        if (!containerRef.current) {
            return;
        }

        //
        // Allows other components to scroll the gallery.
        //
        setScrollToHandler(scrollTop => {
            containerRef.current!.scrollTo({ top: scrollTop, behavior: "instant" } as any); //TODO: Remove the "as any" when the types are updated in TS 5.1+.
        });

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

    const visibleRange = renderVisibleRange(layout, scrollTop, containerRef.current?.clientHeight, scrollDistance.current > 10, theme, onItemClick)

    return (
        <>
            {/* Sticky header */}
            {visibleRange.curHeadingRow &&
                <div
                    style={{
                        position: "absolute",
                        top: 0,
                        zIndex: 100,
                        backgroundColor: theme.palette.background.body,
                        color: theme.palette.text.primary,
                        opacity: 0.75,
                        borderBottom: "1px solid rgba(0,0,0,0.1)",
                        height: `${visibleRange.curHeadingRow.height}px`,
                        width: "100%",
                        fontSize: "0.9rem",
                        fontWeight: 600,
                        lineHeight: "1.25rem",
                        letterSpacing: ".0178571429em",
                        padding: "1em",
                    }}                    
                    >                            
                    {visibleRange.curHeadingRow.heading}
                </div>
            }

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
                    {visibleRange.rows}
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
        </>
    );
}
