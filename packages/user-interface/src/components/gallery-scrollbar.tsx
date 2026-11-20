import React, { useEffect, useRef, useState } from "react";
import { IGalleryLayout } from "../lib/create-layout";
import useResizeObserver from "@react-hook/resize-observer";
import UnfoldMoreIcon from "@mui/icons-material/UnfoldMore";

//
// Gutter above and below the scrollbar.
//
const VERTICAL_GUTTER = 2;

export interface IGalleryScrolbarProps {
    //
    // The ref to the scrollable gallery container.
    //
    scrollContainerRef: React.RefObject<HTMLDivElement | null>;

    //
    // The layout of the gallery.
    //
    galleryLayout: IGalleryLayout;

    //
    // Scrolls the gallery to a specific position.
    //
    scrollTo: (scrollTop: number) => void;
}

//
// A custom scrollbar for the gallery.
//
export function GalleryScrollbar({ scrollContainerRef, galleryLayout, scrollTo }: IGalleryScrolbarProps) {

    const [scrollTop, setScrollTop] = useState(0);
    const [galleryContainerHeight, setGalleryContainerHeight] = useState(0);

    const containerRef = useRef<HTMLDivElement>(null);

    const [scrollbarHeight, setScrollbarHeight] = useState<number>(0);
    const [thumbPos, setThumbPos] = useState<number>(0);
    const [thumbHeight, setThumbHeight] = useState<number>(0);
    const [isDraggingTouch, setIsDraggingTouch] = useState(false);
    const [isDraggingMouse, setIsDraggingMouse] = useState(false);
    const deltaY = useRef(0);

    //
    // The thumb, whose height the --scrubber-thumb-height token sets and the position maths reads.
    //
    const thumbRef = useRef<HTMLDivElement>(null);

    useEffect(() => {
        const container = scrollContainerRef.current;
        if (!container) {
            return;
        }

        setGalleryContainerHeight(container.clientHeight);

        function onScroll() {
            setScrollTop(container!.scrollTop);
        }

        function onResize() {
            setGalleryContainerHeight(container!.clientHeight);
        }

        container.addEventListener('scroll', onScroll);
        window.addEventListener('resize', onResize);

        return () => {
            container.removeEventListener('scroll', onScroll);
            window.removeEventListener('resize', onResize);
        };
    }, [scrollContainerRef]);

    function updateThumbPos(thumbPos: number): void {
        setThumbPos(Math.min(Math.max(VERTICAL_GUTTER, thumbPos), scrollbarHeight - thumbHeight));
    }

    //
    // Updates the scrollbar height based on the height of the container.
    //
    function updateScrollbarHeight() {
        const _scrollbarHeight = (containerRef.current?.clientHeight || 0) - (VERTICAL_GUTTER * 2);
        setScrollbarHeight(_scrollbarHeight);
        updateThumbPos(VERTICAL_GUTTER + (scrollTop / galleryLayout!.galleryHeight) * _scrollbarHeight);
    }

    useEffect(() => {
        if (galleryContainerHeight > 0 && galleryLayout?.galleryHeight > 0 && scrollbarHeight > 0 && thumbRef.current) {
            setThumbHeight(thumbRef.current.offsetHeight);
        }
        else {
            setThumbHeight(0);
        }
    }, [galleryContainerHeight, galleryLayout?.galleryHeight, scrollbarHeight]);
    
    useEffect(() => {
        if (containerRef.current) {
            updateScrollbarHeight();
        }

    }, [scrollTop, galleryLayout]);

    //
    // Mouse support for desktop.
    //
    // Updates the gallery width when the container is resized. The cast is there because version 1
    // of @react-hook/resize-observer types its target as React 18's RefObject, which React 19's
    // nullable RefObject does not match. The hook already copes with a null current.
    //
    useResizeObserver(containerRef as React.RefObject<HTMLDivElement>, () => {
        updateScrollbarHeight();
    });

    useEffect(() => {
        if (isDraggingMouse) {
            function onMouseMove(e: MouseEvent) {
                updateThumbPos(e.clientY - deltaY.current);                
                scrollTo(calcScrollPos(e.clientY - deltaY.current - VERTICAL_GUTTER));
            }

            function onMouseUp() {
                setIsDraggingMouse(false);
            }

            document.addEventListener('mousemove', onMouseMove);
            document.addEventListener('mouseup', onMouseUp);

            return () => {
                document.removeEventListener('mousemove', onMouseMove);
                document.removeEventListener('mouseup', onMouseUp);
            };
        }
    }, [isDraggingMouse, deltaY]);

    //
    // Touch support for mobile.
    //
    useEffect(() => {
        if (isDraggingTouch) {
            function onTouchMove(e: TouchEvent) {
                updateThumbPos(e.touches[0].clientY - deltaY.current);
                scrollTo(calcScrollPos(e.touches[0].clientY - deltaY.current - VERTICAL_GUTTER));
            };

            function onTouchEnd() {
                setIsDraggingTouch(false);
            }

            document.addEventListener('touchmove', onTouchMove);
            document.addEventListener('touchend', onTouchEnd);

            return () => {
                document.removeEventListener('touchmove', onTouchMove);
                document.removeEventListener('touchend', onTouchEnd);
            };
        }
    }, [isDraggingTouch, deltaY]);    

    function onMouseDown(e: React.MouseEvent) {
        deltaY.current = e.clientY - thumbPos;
        setIsDraggingMouse(true);
    };

    function onTouchStart(e: React.TouchEvent) {
        deltaY.current = e.touches[0].clientY - thumbPos;
        setIsDraggingTouch(true);
    };

    //
    // Calculates the scroll position for a mouse Y position.
    //
    function calcScrollPos(mouseY: number): number {
        const percentage = mouseY / scrollbarHeight;
        const scrollY = percentage * galleryLayout!.galleryHeight;
        return Number(Math.min(galleryLayout!.galleryHeight, Math.max(0, scrollY)).toFixed(2));
    }

    if (!galleryLayout) {
        // No layout yet.
        return null;
    }
    
    if (galleryContainerHeight >= galleryLayout.galleryHeight) {
        //
        // The gallery container is big enough to show all the items.
        // No need for a scrollbar.
        //
        return null;
    }

    return (
        <>
            {/* Visible scrollbar */}
            <div
                ref={containerRef}
                className="gallery-scrollbar"
                style={{
                    width: "var(--scrubber-thumb-width)",
                    zIndex: 200,
                }}
                onMouseUp={event => {
                    if (isDraggingTouch || isDraggingMouse) {
                        return;
                    }
                    
                    //
                    // Calculate the percentage of the scrollbar clicked and scroll the gallery to that position.
                    //
                    const scrollbarTop = containerRef.current!.getBoundingClientRect().top;
                    const newScrollPos = calcScrollPos(event.clientY - scrollbarTop - VERTICAL_GUTTER);
                    scrollTo(newScrollPos);
                }}
                >

                {/* The thumb: an accent tab at the right edge, set by the --scrubber-thumb-* tokens. */}
                <div
                    ref={thumbRef}
                    className="gallery-scrollbar-thumb"
                    onMouseDown={onMouseDown}
                    onTouchStart={onTouchStart}
                    style={{
                        position: "absolute",
                        top: `${thumbPos}px`,
                        right: "var(--scrubber-thumb-edge-gap)",
                        boxSizing: "border-box",
                        height: "var(--scrubber-thumb-height)",
                        width: "var(--scrubber-thumb-width)",
                        display: "flex",
                        alignItems: "center",
                        justifyContent: "center",
                        background: "var(--color-scrubber-thumb-bg)",
                        color: "var(--color-scrubber-thumb-text)",
                        border: "var(--scrubber-thumb-border-width) solid var(--color-scrubber-thumb-border)",
                        borderRadius: "var(--radius-scrubber-thumb)",
                        boxShadow: "var(--shadow-scrubber-thumb)",
                        cursor: (isDraggingMouse || isDraggingTouch) ? "grabbing" : "grab",
                    }}
                    >
                    <UnfoldMoreIcon
                        sx={{
                            display: "var(--scrubber-thumb-icon-display)",
                            fontSize: "var(--icon-sm)",
                        }}
                        />
                </div>
            </div>

        </>
    );
}
