import React, { useEffect, useRef, useState } from "react";
import { IGalleryLayout } from "../lib/create-layout";
import { IGalleryRow } from "../lib/gallery-item";
import useResizeObserver from "@react-hook/resize-observer";
import { useTheme } from "@mui/joy";

//
// Width of the custom scrollbar on the right of the gallery.
//
export const SCROLLBAR_WIDTH = 22;

//
// Defines the size of the scrollbar hit test area.
//
const SCROLLBAR_HITTEST_MULTIPLIER = 3;

//
// Gutter above and below the scrollbar.
//
const VERTICAL_GUTTER = 2;

//
// Minimum height of the scrollbar thumb.
//
const MIN_SCROLLTHUMB_HEIGHT = 42;

export interface IGalleryScrolbarProps {
    //
    // The height of the div that contains the gallery.
    //
    galleryContainerHeight: number;

    //
    // The layout of the gallery.
    //
    galleryLayout: IGalleryLayout;

    //
    // The current scroll position of the gallery.
    //
    scrollTop: number;

    //
    // Scrolls the gallery to a specific position.
    //
    scrollTo: (scrollTop: number) => void;

    //
    // Event raised when dragging has started.
    //
    onDraggingStarted: () => void;

    //
    // Event raised when dragging has ended.
    //
    onDraggingEnded: () => void;
}

//
// A custom scrollbar for the gallery.
//
export function GalleryScrollbar({ galleryContainerHeight, galleryLayout, scrollTop, scrollTo, onDraggingStarted, onDraggingEnded }: IGalleryScrolbarProps) {

    const containerRef = useRef<HTMLDivElement>(null);

    const [scrollbarHeight, setScrollbarHeight] = useState<number>(0);
    const [thumbPos, setThumbPos] = useState<number>(0);
    const [thumbHeight, setThumbHeight] = useState<number>(0);
    const [isDraggingTouch, setIsDraggingTouch] = useState(false);
    const [isDraggingMouse, setIsDraggingMouse] = useState(false);
    const [isTouchDevice, setIsTouchDevice] = useState(false);
    const deltaY = useRef(0);
    const theme = useTheme();

    useEffect(() => {
        // Check if it's a touch device
        const checkTouchDevice = () => {
            setIsTouchDevice('ontouchstart' in window || navigator.maxTouchPoints > 0);
        };
        checkTouchDevice();
        window.addEventListener('resize', checkTouchDevice);

        // Cleanup event listener on unmount
        return () => window.removeEventListener('resize', checkTouchDevice);
    }, []);

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
        if (galleryContainerHeight > 0 && galleryLayout?.galleryHeight > 0 && scrollbarHeight > 0) {
            setThumbHeight(Math.min(Math.max(MIN_SCROLLTHUMB_HEIGHT, (galleryContainerHeight / galleryLayout?.galleryHeight) * scrollbarHeight), scrollbarHeight - VERTICAL_GUTTER - VERTICAL_GUTTER));
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
    // Updates the gallery width when the container is resized.
    //
    useResizeObserver(containerRef, () => {
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

                onDraggingEnded();
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
                
                onDraggingEnded();
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

        onDraggingStarted();
    };

    function onTouchStart(e: React.TouchEvent) {
        deltaY.current = e.touches[0].clientY - thumbPos;
        setIsDraggingTouch(true);

        onDraggingStarted();
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
                    width: `${SCROLLBAR_WIDTH}px`,
                    backgroundColor: theme.palette.background.body,
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

                {/* The thumb */}
                <div
                    className="gallery-scrollbar-thumb"
                    onMouseDown={onMouseDown}
                    onTouchStart={onTouchStart}
                    style={{
                        position: "absolute",
                        top: `${thumbPos}px`,
                        height: `${thumbHeight}px`,
                        width: `${SCROLLBAR_WIDTH}px`,
                    }}
                    >
                </div>
            </div>

            {/* Invisible scrollbar for hit testing */  }
            {isTouchDevice &&
                <div
                    className="gallery-scrollbar"
                    style={{
                        width: `${SCROLLBAR_WIDTH*SCROLLBAR_HITTEST_MULTIPLIER}px`,
                        opacity: 0,
                        pointerEvents: "auto",
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

                    {/* The thumb */}
                    <div
                        className="gallery-scrollbar-thumb"
                        onMouseDown={onMouseDown}
                        onTouchStart={onTouchStart}
                        style={{
                            position: "fixed",
                            top: `${thumbPos}px`,
                            height: `${thumbHeight}px`,
                            width: `${SCROLLBAR_WIDTH*SCROLLBAR_HITTEST_MULTIPLIER}px`,
                        }}
                        >
                    </div>
                </div>
            }
        </>
    );
}
