import React from "react";
import { createLayout } from "./create-layout";
import { IGalleryItem } from "./gallery-item";

export interface IGalleryLayoutProps { 
    //
    // The items to display in the gallery.
    //
	items: IGalleryItem[];

    //
    // The width of the gallery.
    //
	galleryWidth?: number;

    //
    // The target height for rows in the gallery.
    //
	targetRowHeight?: number;

    //
    // The URL for the backend.
    //
	baseUrl: string;

    //
    // Event raised when an item in the gallery has been clicked.
    //
    onItemClick: ((item: IGalleryItem) => void) | undefined;
}

//
// Responsible for row-based gallery layout.
//
export function GalleryLayout({
	items = [], 
	galleryWidth = 600, 
	targetRowHeight = 150, 
	baseUrl = "",
    onItemClick = undefined,
    }: IGalleryLayoutProps) {

    const gutter = 8; // Small gutter to make sure the edge or each rows is not visible.
    const rows = createLayout(items, galleryWidth + gutter, targetRowHeight);

    let prevGroup: string | undefined = undefined;

    return (
        <div
            style={{
                width: `${galleryWidth}px`,
                overflowX: "hidden",
            }}
            >
            {rows.map((row, rowIndex) => {
                const items = [];
                if (row.group !== prevGroup) {
                    items.push(
                        <div 
                            key={row.group}
                            style={{
                                fontSize: "0.9rem",
                                color: "rgb(60,64,67)",
                                fontWeight: 600,
                                lineHeight: "1.25rem",
                                letterSpacing: ".0178571429em",
                                padding: "1em",
                            }}
                            >
                            {row.group}
                        </div>
                    );
                    prevGroup = row.group;
                }
                items.push(
                    <div
                        key={rowIndex}
                        style={{
                            display: "flex",
                            flexDirection: "row",
                            height: `${row.height}px`,
                        }}
                        >
                        {row.items.map(item => {
                            return (
                                <img 
                                    style={{
                                        padding: "2px",
                                    }}
                                    onClick={() => {
                                        if (onItemClick) {
                                            onItemClick(item) 
                                        }
                                    }}
                                    key={item.thumb}
                                    src={`${baseUrl}${item.thumb}`}
                                    />
                            );
                        })}
                    </div>
                );
                return items;
            })}

        </div>
    );
}

