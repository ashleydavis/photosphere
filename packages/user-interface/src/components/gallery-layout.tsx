import React, { useEffect, useRef, useState } from "react";
import { IGalleryItem, IGalleryRow } from "../lib/gallery-item";
import { GalleryScrollbar } from "./gallery-scrollbar";
import { GalleryImage } from "./gallery-image";
import { useGalleryLayout } from "../context/gallery-layout-context";
import { useVirtualizer } from '@tanstack/react-virtual'
import { GalleryPreview } from "./gallery-preview";
import { Theme, useTheme } from "@mui/joy";
import _ from "lodash";

export type ItemClickFn = ((item: IGalleryItem) => void);

//
// Renders a row of items in the gallery.
//
function renderRow(row: IGalleryRow, rowIndex: number, onItemClick: ItemClickFn | undefined, shouldLoad: boolean) {
    if (row.type === "heading") {
        //
        // Renders a heading row.
        //
        return (
            <div 
                key={rowIndex}
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
            style={{
                position: "absolute",
                top: `${row.offsetY}px`,
                left: 0,
                width: "100%",
                height: `${row.height}px`,
            }}
            >
            {row.items.map(item => {
                return (
                    <GalleryImage
                        key={item._id}
                        item={item}
                        onClick={() => {
                            if (onItemClick) {
                                onItemClick(item);
                            }
                        }}
                        x={item.offsetX!}
                        y={0}
                        width={item.thumbWidth!}
                        height={item.thumbHeight!}
                        shouldLoad={shouldLoad}
                        />
                );
            })}
        </div>        
    );
}

//
// Renders a row of items in the gallery.
//
function renderPreviewRow(row: IGalleryRow, rowIndex: number) {
    if (row.type === "heading") {
        //
        // Renders a heading row.
        //
        return (
            <div 
                key={rowIndex}
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
            style={{
                position: "absolute",
                top: `${row.offsetY}px`,
                left: 0,
                width: "100%",
                height: `${row.height}px`,
            }}
            >
            {row.items.map(item => {
                return (
                    <GalleryPreview
                        key={item._id}
                        item={item}
                        x={item.offsetX!}
                        y={0}
                        width={item.thumbWidth!}
                        height={item.thumbHeight!}
                        />
                );
            })}
        </div>        
    );
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

    //
    // Set to true when the scrollbar is being dragged.
    //
    const [ isDragging, setIsDragging ] = useState(false);

    //
    // Set to true when the gallery is being scrolled.
    //
    const [ isScrolling, setIsScrolling ] = useState(false);

    const containerRef = useRef<HTMLDivElement>(null);  

    const theme = useTheme();

    //
    // Handles scrolling.
    //
    useEffect(() => {
        if (!containerRef.current) {
            return;
        }

        const container = containerRef.current;

        //
        // Allows other components to scroll the gallery.
        //
        setScrollToHandler(scrollTop => {
            container.scrollTo({ top: scrollTop, behavior: "instant" } as any); //TODO: Remove the "as any" when the types are updated in TS 5.1+.
        });        

        function onScroll() {
            setScrollTop(container.scrollTop);
        }

        container.addEventListener('scroll', onScroll);

        return () => {
            container.removeEventListener('scroll', onScroll);
        };
    }, []);

    const rowVirtualizer = useVirtualizer({
        count: layout?.rows.length || 0,
        getScrollElement: () => containerRef.current,
        estimateSize: (i) => layout?.rows[i].height || 0,
        overscan: 10,
    });

    //
    // Rows that are currently visible in the viewport.
    //
    const virtualRows = rowVirtualizer.getVirtualItems();

    //
    // Find the previous heading row.
    //
    let stickyHeading = useRef<IGalleryRow | undefined>(undefined);
    let stickHeadingVisible = useRef<boolean>(false);

    if (layout && virtualRows.length > 0) {
        const startingRow = virtualRows[0].index;

        if (layout!.rows[startingRow].type === "heading") {
            // If the first row is a heading, then don't display a sticky heading.
            stickHeadingVisible.current = false;
        }
        else if (startingRow + 1 < layout!.rows.length && layout!.rows[startingRow + 1].type === "heading") {
            // If the first row is a heading, then don't display a sticky heading.
            stickHeadingVisible.current = false;
        }
        else {
            //
            // Find the previous heading row.
            //
            for (let i = startingRow-1; i >= 0; i--) {
                const row = layout!.rows[i];
                if (row.type === "heading") {
                    stickyHeading.current = row;
                    stickHeadingVisible.current = true;
                    break;
                }
            }
        }      
    }
    else {
        stickHeadingVisible.current = false;
    }

    const scrollStartTimeoutRef = useRef<NodeJS.Timeout | undefined>(undefined);

    // Create throttled function that sets isScrolling to false.
    const setScrollingFalse = useRef(
        _.debounce(() => {
            setIsScrolling(false);
        }, 800, { leading: false, trailing: true })
    ).current;
        
    // Watch virtualizer.isScrolling and update our state.
    useEffect(() => {
        if (rowVirtualizer.isScrolling) {
            // Clear any existing timeout.
            clearTimeout(scrollStartTimeoutRef.current);
            
            // Set isScrolling to true after delay.
            scrollStartTimeoutRef.current = setTimeout(() => {
                setIsScrolling(true);
            }, 2000)
            
            // Cancel any pending throttled call.
            setScrollingFalse.cancel();
        } 
        else {
            // Clear the timeout if scrolling stopped for a bit.
            clearTimeout(scrollStartTimeoutRef.current);
            
            // If isScrolling was already true, wait before setting to false.
            if (isScrolling) {
                setScrollingFalse();
            }
        }
    }, [rowVirtualizer.isScrolling, setScrollingFalse, isScrolling]);

    return (
        <>
            {stickyHeading.current &&
                <div
                    className={`gallery-sticky-heading ` + (stickHeadingVisible.current ? "fade-in" : "fade-out")}
                    style={{
                        position: "absolute",
                        top: 0,
                        zIndex: 100,
                        backgroundColor: theme.palette.background.body,
                        color: theme.palette.text.primary,
                        borderBottom: "1px solid rgba(0,0,0,0.1)",
                        height: `${stickyHeading.current.height}px`,
                        width: "100%",
                        fontSize: "0.9rem",
                        fontWeight: 600,
                        lineHeight: "1.25rem",
                        letterSpacing: ".0178571429em",
                        padding: "1em",
                    }}                    
                    >                            
                    {stickyHeading.current.heading}
                </div>
            }           

            <div
                className="gallery-scroller"
                ref={containerRef}
                style={{
                    overflowX: "hidden",
                    height: "100%",
                    position: "relative", //todo: prolly don't need this!
                    overflowY: "scroll",
                }}
                >

                <div
                    style={{
                        width: `${galleryWidth}px`,
                        height: `${rowVirtualizer.getTotalSize()}px`,
                        overflowX: "hidden",
                        position: "relative",
                    }}
                    >

                    {/* {(isDragging || rowVirtualizer.isScrolling)
                        ? virtualRows.map(virtualRow => {
                            return renderPreviewRow(layout!.rows[virtualRow.index], virtualRow.index);
                        })
                        : virtualRows.map(virtualRow => {
                            return renderRow(layout!.rows[virtualRow.index], virtualRow.index, onItemClick, isDragging || rowVirtualizer.isScrolling);
                        })

                    } */}

                    {/* {virtualRows.map(virtualRow => {
                        return renderPreviewRow(layout!.rows[virtualRow.index], virtualRow.index);
                    })} */}

                    {/* Removing this next bit reduces memory a lot! */}

                    {virtualRows.map(virtualRow => {
                        return renderRow(layout!.rows[virtualRow.index], virtualRow.index, onItemClick, !isDragging && !isScrolling);
                    })}
                    
                </div>

                {layout
                    && <GalleryScrollbar
                        galleryContainerHeight={containerRef.current?.clientHeight || 0}
                        galleryLayout={layout}
                        scrollTop={scrollTop}
                        scrollTo={scrollPosition => {
                            containerRef.current!.scrollTo({ top: scrollPosition, behavior: "instant" } as any); //TODO: Remove the "as any" when the types are updated in TS 5.1+.
                        }}
                        onDraggingStarted={() => {
                            setIsDragging(true);
                        }}
                        onDraggingEnded={() => {
                            setIsDragging(false);
                        }}
                        />
                }

            </div>
        </>
    );
}
