import React from "react";
import { IGalleryRow, ISelectedGalleryItem } from "../lib/gallery-item";
import { Image } from "./image";
import { useGallery } from "../context/gallery-context";
import { computePartialLayout } from "../lib/create-layout";
import { GalleryImage } from "./gallery-image";

export type ItemClickFn = ((item: ISelectedGalleryItem) => void);

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
                        itemIndex={(row.startingIndex + index)}
                        onClick={() => {
                            if (onItemClick) {
                                onItemClick({ 
                                    item, 
                                    index: row.startingIndex + index 
                                });
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

    const { assets } = useGallery();
    
    const galleryLayout = computePartialLayout(undefined, assets, galleryWidth, targetRowHeight);

    return (
        <div
            style={{
                width: `${galleryWidth}px`,
                height: `${galleryLayout?.galleryHeight}px`,
                overflowX: "hidden",
                position: "relative",
            }}
            >
            {galleryLayout.rows.map((row, rowIndex) => {
                return (
                    <div
                        key={rowIndex}
                        style={{
                            display: "flex",
                            flexDirection: "row",
                            height: `${row.height}px`,
                        }}
                        >
                        {renderRow(row, rowIndex, onItemClick)}
                    </div>
                );
            })}

        </div>
    );
}
