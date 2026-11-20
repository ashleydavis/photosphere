import React, { useEffect, useRef } from "react";
import { IGalleryItem, IGalleryRow } from "../lib/gallery-item";
import { GalleryScrollbar } from "./gallery-scrollbar";
import { GalleryImage } from "./gallery-image";
import { useGalleryLayout } from "../context/gallery-layout-context";
import { useVirtualizer } from '@tanstack/react-virtual'
import { log } from "utils";

export type ItemClickFn = ((item: IGalleryItem) => void);

//
// Minimum scroll speed in pixels per frame when an arrow key is first pressed.
//
const ARROW_SCROLL_MIN_SPEED = 3;

//
// Maximum scroll speed in pixels per frame after holding an arrow key.
//
const ARROW_SCROLL_MAX_SPEED = 40;

//
// Time in milliseconds to accelerate from min to max speed for arrow keys.
//
const ARROW_SCROLL_ACCEL_MS = 1200;

//
// Minimum scroll speed in pixels per frame when a page key is first pressed.
//
const PAGE_SCROLL_MIN_SPEED = 10;

//
// Maximum scroll speed in pixels per frame after holding a page key.
//
const PAGE_SCROLL_MAX_SPEED = 80;

//
// Time in milliseconds to accelerate from min to max speed for page keys.
//
const PAGE_SCROLL_ACCEL_MS = 200;

//
// State for the active arrow key scroll loop.
//
interface IArrowScroll {
    // Direction of scroll: 1 for down, -1 for up.
    direction: number;

    // Animation frame ID for the current scroll loop.
    rafId: number;

    // Timestamp when the arrow key was first pressed.
    startTime: number;
}

//
// The look of a month heading, shared by the heading rows and the heading that stays at the top
// while its photos scroll under it: a frosted bar set by the --date-heading-* tokens.
//
const DATE_HEADING_STYLE: React.CSSProperties = {
    boxSizing: "border-box",
    padding: "var(--date-heading-padding)",
    fontFamily: "var(--date-heading-font)",
    fontSize: "var(--date-heading-size)",
    fontWeight: "var(--weight-bold)",
    lineHeight: "var(--leading-tight)",
    color: "var(--color-text)",
    background: "var(--color-date-heading-bg)",
    borderRadius: "var(--radius-date-heading)",
    boxShadow: "var(--shadow-date-heading)",
    backdropFilter: "blur(var(--date-heading-blur))",
    WebkitBackdropFilter: "blur(var(--date-heading-blur))",
    whiteSpace: "nowrap",
    overflow: "hidden",
    textOverflow: "ellipsis",
};

//
// Renders a row of items in the gallery. Each photo but the last is drawn up to where the next one
// starts, less `galleryGap`, so the space the layout adds between photos to fit a row to the
// gallery's width goes into the photos instead of opening a seam wider than the gap between them.
//
function renderRow(row: IGalleryRow, rowIndex: number, galleryGap: number, onItemClick: ItemClickFn | undefined) {
    if (row.type === "heading") {
        //
        // Renders a heading row.
        //
        return (
            <div 
                key={rowIndex}
                style={{
                    ...DATE_HEADING_STYLE,
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
            {row.items.map((item, itemIndex) => {
                let width = item.thumbWidth!;
                if (itemIndex < row.items.length - 1) {
                    width = row.items[itemIndex + 1].offsetX! - galleryGap - item.offsetX!;
                }
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
                        width={Math.max(item.thumbWidth!, width)}
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

    const { galleryWidth, galleryGap, layout, setScrollToHandler } = useGalleryLayout();

    const containerRef = useRef<HTMLDivElement>(null);

    //
    // Tracks the active arrow key scroll loop, if any.
    //
    const arrowScrollRef = useRef<IArrowScroll | undefined>(undefined);

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

        function startAcceleratingScroll(direction: number, minSpeed: number, maxSpeed: number, accelMs: number) {
            if (arrowScrollRef.current) {
                return;
            }
            const startTime = performance.now();
            function frame() {
                const elapsed = performance.now() - startTime;
                const t = Math.min(elapsed / accelMs, 1);
                const speed = minSpeed + (maxSpeed - minSpeed) * t;
                container.scrollBy({ top: direction * speed, behavior: "instant" } as any);
                arrowScrollRef.current!.rafId = requestAnimationFrame(frame);
            }
            arrowScrollRef.current = {
                direction,
                rafId: requestAnimationFrame(frame),
                startTime,
            };
        }

        function stopArrowScroll() {
            if (arrowScrollRef.current) {
                cancelAnimationFrame(arrowScrollRef.current.rafId);
                arrowScrollRef.current = undefined;
            }
        }

        function onKeyDown(event: KeyboardEvent) {
            const tag = (document.activeElement as HTMLElement)?.tagName?.toLowerCase();
            if (tag === "input" || tag === "textarea" || tag === "select" || tag === "button") {
                return;
            }
            if (event.key === "ArrowDown") {
                event.preventDefault();
                startAcceleratingScroll(1, ARROW_SCROLL_MIN_SPEED, ARROW_SCROLL_MAX_SPEED, ARROW_SCROLL_ACCEL_MS);
            }
            else if (event.key === "ArrowUp") {
                event.preventDefault();
                startAcceleratingScroll(-1, ARROW_SCROLL_MIN_SPEED, ARROW_SCROLL_MAX_SPEED, ARROW_SCROLL_ACCEL_MS);
            }
            else if (event.key === "PageDown") {
                event.preventDefault();
                startAcceleratingScroll(1, PAGE_SCROLL_MIN_SPEED, PAGE_SCROLL_MAX_SPEED, PAGE_SCROLL_ACCEL_MS);
            }
            else if (event.key === "PageUp") {
                event.preventDefault();
                startAcceleratingScroll(-1, PAGE_SCROLL_MIN_SPEED, PAGE_SCROLL_MAX_SPEED, PAGE_SCROLL_ACCEL_MS);
            }
            else if (event.key === "Home") {
                event.preventDefault();
                container.scrollTo({ top: 0, behavior: "instant" } as any);
            }
            else if (event.key === "End") {
                event.preventDefault();
                container.scrollTo({ top: container.scrollHeight, behavior: "instant" } as any);
            }
        }

        function onKeyUp(event: KeyboardEvent) {
            if (event.key === "ArrowDown" || event.key === "ArrowUp" || event.key === "PageDown" || event.key === "PageUp") {
                stopArrowScroll();
            }
        }

        window.addEventListener("keydown", onKeyDown);
        window.addEventListener("keyup", onKeyUp);

        return () => {
            window.removeEventListener("keydown", onKeyDown);
            window.removeEventListener("keyup", onKeyUp);
            stopArrowScroll();
        };
    }, []);

    const rowVirtualizer = useVirtualizer({
        count: layout?.rows.length || 0,
        getScrollElement: () => containerRef.current,
        estimateSize: (i) => layout?.rows[i].height || 0,
        overscan: 3,
    });

    //
    // Rows that are currently visible in the viewport.
    //
    const virtualRows = rowVirtualizer.getVirtualItems();

    useEffect(() => {
        if (virtualRows.length > 0) {
            log.event(`Gallery items rendered`);
        }
    }, [virtualRows.length]);

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

    return (
        <>
            {stickyHeading.current &&
                <div
                    className={`gallery-sticky-heading ` + (stickHeadingVisible.current ? "fade-in" : "fade-out")}
                    style={{
                        ...DATE_HEADING_STYLE,
                        position: "absolute",
                        top: 0,
                        zIndex: 100,
                        height: `${stickyHeading.current.height}px`,
                        width: `${galleryWidth}px`,
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

                    {virtualRows.map(virtualRow => {
                        return renderRow(layout!.rows[virtualRow.index], virtualRow.index, galleryGap, onItemClick);
                    })}
                    
                </div>

            </div>

            {/* The fast-scroll handle sits beside the scroller rather than in it, so it stays put
                at the right edge of the page area while the photos scroll. */}
            {layout
                && <GalleryScrollbar
                    scrollContainerRef={containerRef}
                    galleryLayout={layout}
                    scrollTo={scrollPosition => {
                        containerRef.current!.scrollTo({ top: scrollPosition, behavior: "instant" } as any); //TODO: Remove the "as any" when the types are updated in TS 5.1+.
                    }}
                    />
            }
        </>
    );
}
