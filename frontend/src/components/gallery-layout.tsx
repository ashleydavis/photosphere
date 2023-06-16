import React from "react";
import { createLayout } from "../lib/create-layout";
import { IGalleryItem, ISelectedGalleryItem } from "../lib/gallery-item";
import { useApi } from "../context/api-context";

export interface IGalleryLayoutProps { 
    //
    // The items to display in the gallery.
    //
	items: IGalleryItem[];

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
    onItemClick: ((item: ISelectedGalleryItem) => void) | undefined;
}

//
// Responsible for row-based gallery layout.
//
export function GalleryLayout({
	items = [], 
	galleryWidth = 600, 
	targetRowHeight = 150, 
    onItemClick = undefined,
    }: IGalleryLayoutProps) {

    //
    // Interface to the API.
    //
    const api = useApi();
    
    const rows = createLayout(items, galleryWidth, targetRowHeight);

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
                        {row.items.map((item, index) => {
                            return (
                                <img 
                                    data-testid="gallery-thumb"
                                    style={{
                                        padding: "2px",
                                    }}
                                    onClick={() => {
                                        if (onItemClick) {
                                            onItemClick({ item, index });
                                        }
                                    }}
                                    key={item._id}
                                    src={api.makeUrl(`/thumb?id=${item._id}`)}
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
