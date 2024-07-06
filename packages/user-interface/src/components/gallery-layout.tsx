import React, { useEffect, useRef, useState } from "react";
import { IGalleryItem, IGalleryRow } from "../lib/gallery-item";
import { useGallery } from "../context/gallery-context";
import { IGalleryLayout, computePartialLayout } from "../lib/create-layout";
import { GalleryImage } from "./gallery-image";
import { throttle } from "lodash";

export type ItemClickFn = ((item: IGalleryItem) => void);

//
// Renders a row of items in the gallery.
//
function renderRow(row: IGalleryRow, rowIndex: number, onItemClick: ItemClickFn | undefined) {
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
function renderVisibleRange(galleryLayout: IGalleryLayout | undefined, scrollTop: number, contentHeight: number | undefined, onItemClick: ItemClickFn | undefined) {
    if (!contentHeight || !galleryLayout) {
        return [];
    }

    const range = findVisibleRange(galleryLayout, scrollTop, contentHeight);
    if (!range) {
        return [];
    }

    const renderedRows: JSX.Element[] = [];

    //
    //  rows actually on screen with a higher priority.
    //
    for (let rowIndex = range.startIndex; rowIndex <= range.endIndex; rowIndex++) {
        const row = galleryLayout.rows[rowIndex];

        //
        // Only render rows actually on screen.
        //
        renderedRows.push(renderRow(row, rowIndex, onItemClick));
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
}

//
// Responsible for row-based gallery layout.
//
export function GalleryLayout({
	galleryWidth = 600, 
	targetRowHeight = 150, 
    onItemClick = undefined,
    }: IGalleryLayoutProps) {

    const { items } = useGallery();
    
    const containerRef = useRef<HTMLDivElement>(null);
    const [ scrollTop, setScrollTop ] = useState(0);
    
    //
    // The layout of the gallery.
    //
    const [layout, setLayout] = useState<IGalleryLayout | undefined>(undefined);

    //
    // Computes the gallery layout.
    //
    useEffect(() => {
        setLayout(computePartialLayout(undefined, items, galleryWidth, targetRowHeight));
    }, [items, galleryWidth, targetRowHeight]);

    //
    // Handles scrolling.
    //
    useEffect(() => {
        if (!containerRef.current) {
            return;
        }

        const container = containerRef.current;

        const onScroll = throttle(() => {
            setScrollTop(container.scrollTop);
        }, 10);
        
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
                {renderVisibleRange(layout, scrollTop, containerRef.current?.clientHeight, onItemClick)}
            </div>
        </div>
    );
}
