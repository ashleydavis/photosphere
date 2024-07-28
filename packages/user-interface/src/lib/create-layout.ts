
//
// Creates a row-based layout for the photo gallery.
//

import dayjs from "dayjs";
import { IGalleryItem, IGalleryRow } from "./gallery-item";
import { getImageDimensions } from "./image";

export interface IGalleryLayout {
    //
    // Rows of the layout.
    //
    rows: IGalleryRow[];

    //
    // The entire height of the gallery.
    //
    galleryHeight: number;
}

//
// Returns true if two sets of hedadings match.
//
function headingsMatch(headingsA: string[], headingsB: string[]): boolean {
    if (headingsA.length !== headingsB.length) {
        return false;
    }

    for (let i = 0; i < headingsA.length; i++) {
        if (headingsA[i] !== headingsB[i]) {
            return false;
        }
    }

    return true;
}

//
// Gets headings from an item.
//
export type GetHeadingsFn = (item: IGalleryItem) => string[];

//
// Creates or updates a row-based layout for items in the gallery.
//
export function computePartialLayout(layout: IGalleryLayout | undefined, items: IGalleryItem[], galleryWidth: number, targetRowHeight: number, getHeadings: GetHeadingsFn | undefined): IGalleryLayout {

    if (!layout) {
        layout = {
            rows: [],
            galleryHeight: 0,
        };
    }

    if (!items || !items.length) {
        return layout;
    }

    const rows = layout.rows;

    let curRow: IGalleryRow;
    let startingRowIndex = 0;

    if (rows.length === 0) {  
        //
        // Add the first row.
        //
        curRow = {
            items: [],
            offsetY: 0,
            height: targetRowHeight,
            width: 0,
            headings: [],
        };
    
        rows.push(curRow);
    }
    else {
        //
        // Resume the previous row.
        //
        startingRowIndex = rows.length-1;
        curRow = rows[startingRowIndex];
    }

    //
    // Initially assign each gallery item to a series of rows.
    //
    for (let itemIndex = 0; itemIndex < items.length; itemIndex++) {
        const item = items[itemIndex];
        const resolution = getImageDimensions({ width: item.width, height: item.height }, item.properties?.exif?.Orientation?.[0]);
        const aspectRatio = resolution.width / resolution.height;
        const computedWidth = targetRowHeight * aspectRatio;

        // 
        // Compute headings for the item.
        // TODO: This should be customizable. Heading could also be location (country, city, suburb, etc) or something else.
        //
        const itemHeadings = getHeadings ? getHeadings(item) : [];

        if (curRow.items.length > 0) {
            if (curRow.width + computedWidth > galleryWidth) {
                //
                // Break row on width.
                //
                curRow = {
                    items: [],
                    offsetY: 0,
                    height: targetRowHeight,
                    width: 0,
                    headings: itemHeadings,
                };
                rows.push(curRow);
            }
            else if (!headingsMatch(curRow.headings, itemHeadings)) {
                //
                // Break row on headings.
                //
                curRow = { //TODO: This should be optional.
                    items: [],
                    offsetY: 0,
                    height: targetRowHeight,
                    width: 0,
                    headings: itemHeadings,
                };
                rows.push(curRow);
            }
        }
        else {
            curRow.headings = itemHeadings;
        }

        //
        // Updated computed thumb resolution.
        //
        item.thumbWidth = computedWidth;
        item.thumbHeight = targetRowHeight;
        item.aspectRatio = aspectRatio;

        //
        // Add the item to the row.
        //
        curRow.items.push(item);
        curRow.width += computedWidth;
    }

    //
    // For all rows, except the last row, stretch the items towards the right hand boundary.
    //
    for (let rowIndex = startingRowIndex; rowIndex < rows.length-1; rowIndex++) {
        const row = rows[rowIndex];
        const nextRow = rows[rowIndex+1];
        if (!headingsMatch(row.headings, nextRow.headings)) {
            continue; // Don't expand the last row in each group.
        }

        const gap = galleryWidth - row.width;
        const deltaWidth = gap / row.items.length;

        let maxThumbHeight = 0;
        row.width = 0;

        //
        // Expand each item to fill the gap.
        //
        for (const item of row.items) {
            item.thumbWidth! += deltaWidth;
            item.thumbHeight = item.thumbWidth! * (1.0 / item.aspectRatio!);
            row.width += item.thumbWidth!;
            maxThumbHeight = Math.max(maxThumbHeight, item.thumbHeight);
        }

        computeFromHeight(row, maxThumbHeight);
    }

    //
    // Now pull back the width of all rows so they don't overlap the right hand edge by too much.
    //
    for (let rowIndex = startingRowIndex; rowIndex < rows.length-1; rowIndex++) {
        const row = rows[rowIndex];
        const nextRow = rows[rowIndex+1];
        if (!headingsMatch(row.headings, nextRow.headings)) {
            continue; // Don't expand the last row in each group.
        }

        let pullback = 1;
        let origHeight = row.height;
        let prevHeight = origHeight;

        while (true) {

            const newHeight = origHeight - pullback;
            computeFromHeight(row, newHeight);

            if (row.width < galleryWidth) {
                //
                // Pulled the row width in too far, restore the previous height.
                //
                computeFromHeight(row, prevHeight);
                break;
            }

            prevHeight = newHeight;
            
            // 
            // Each time we double the amount of pullback we try. It
            // results in too many iterations if we advance this by one each loop.
            //
            pullback *= 2;
        }
    }

    //
    // Add group headings.
    //
    let prevHeadings: string[] = [];

    for (let rowIndex = startingRowIndex; rowIndex < rows.length; rowIndex++) {
        const row = rows[rowIndex];
        if (!headingsMatch(row.headings, prevHeadings)) {
            rows.splice(rowIndex, 0, {
                type: "heading",
                items: [],
                offsetY: 0,
                height: 45,
                width: 0, // This isn't needed.
                headings: row.headings,
            });
            rowIndex += 1;
        }
        
        prevHeadings = row.headings;
    }

    //
    // Computes the offsets of each row and total height of the gallery.
    //

    for (let rowIndex = startingRowIndex; rowIndex < rows.length; rowIndex++) {
        const row = rows[rowIndex];
        row.offsetY = layout.galleryHeight;
        layout.galleryHeight += row.height;

        let accumulatedWidth = 0;

        for (const item of row.items) {
            item.offsetX = accumulatedWidth;
            accumulatedWidth += item.thumbWidth!;
        }
    }

    return layout;
}

//
// Compute thumbnail resolution from a requested height.
//
function computeFromHeight(row: IGalleryRow, height: number): void {
    row.height = height;
    row.width = 0;

    for (const item of row.items) {
        item.thumbHeight = height;
        item.thumbWidth = row.height * item.aspectRatio!;
        row.width += item.thumbWidth;
    }
}