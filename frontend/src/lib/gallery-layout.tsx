import React from "react";
import { createLayout } from "./create-layout";

export interface IGalleryLayoutProps { 
	items: any[];
	galleryWidth: number;
	targetRowHeight: number;
	baseUrl: string;
    onImageClick: ((item: any) => {}) | undefined;
}

//
// Responsible for row-based gallery layout.
//
export function GalleryLayout({
	items = [], 
	galleryWidth = 600, 
	targetRowHeight = 150, 
	baseUrl = "",
    onImageClick = undefined,
    }: IGalleryLayoutProps) {

    const gutter = 8; // Small gutter to make sure the edge or each rows is not visible.
    const rows = createLayout(items, galleryWidth + gutter, targetRowHeight);

    let prevGroup: any = undefined;

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
                        {row.items.map((item: any) => {
                            return (
                                <img 
                                    style={{
                                        padding: "2px",
                                    }}
                                    onClick={() => {
                                        if (onImageClick) {
                                            onImageClick(item) 
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

