
//
// Creates a row-based layout for the photo gallery.
//

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
    else {
        //
        // Have to create a fresh object so the state updates.
        //
        layout = {
            ...layout,
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

        let orientation = 1;
        if (item.properties?.exif?.Orientation) {
            orientation = item.properties.exif.Orientation?.[0];        
        }
        else if (item.properties?.metadata?.Orientation) {
            orientation = item.properties.metadata.Orientation?.[0];
        }
    
        const resolution = getImageDimensions({ width: item.width, height: item.height }, orientation);
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
        let prevPullback = 1;
        const origHeight = row.height;

        //
        // Used to place a small gutter at the right hand edge of the gallery.
        // Ideally this would be 0, but somehow that causes an infinite loop!
        // IT NEEDS TO BE SET TO AT LEAST 1 UNTIL IF CAN FIGURE OUT WHAT THE PROBLEM IS.
        //
        const gutter = 1;

        //
        // SLOW VERSION:
        //
        // Slowly pulls the row in until it is less than the gallery width.
        // This is the slow version. It is accurate but takes longer.
        // //
        // while (true) {

        //     // 
        //     // Slowly pull the width back to the right size.
        //     //
        //     pullback += 1;

        //     computeFromHeight(row, origHeight - pullback);

        //     if (row.width < galleryWidth - gutter) {
        //         // We have pulled back too far. We are done here.
        //         pullback = prevPullback;
        //         break;
        //     }

        //     prevPullback = pullback;
        // }

        //
        // FAST VERSION
        //
        // Quickly pulls the row in until it is less than the gallery width.
        // Doubles the amount of pullback each time.
        //
        while (true) {

            // 
            // Quckly pulls the row in.
            //
            pullback *= 2;

            computeFromHeight(row, origHeight - pullback);

            if (row.width < galleryWidth - gutter) {
                // We have pulled in too far. Move onto the next phase.
                break;
            }            
        }

        //
        // Quicly pushes the row out until it is greater than the gallery width.
        // This reduces the pullback quickly so we don't waste time incrementing by one each time.
        //
        while (true) {            
            // 
            // Quickly push the row out.
            //
            prevPullback = pullback;
            pullback *= 0.75;

            computeFromHeight(row, origHeight - pullback);

            if (row.width >= galleryWidth - gutter) {
                // We have pushed out too far. Move onto the next phase.
                pullback = prevPullback;
                break;
            }
        }

        //
        // Slowly pushes the right out until it is greater than the gallery width.
        // Now that we are close, we can increment by one each time for accuracy.
        //
        while (true) {
            
            // 
            // Slowly pushes the row out.
            //
            prevPullback = pullback;
            pullback -= 1;

            computeFromHeight(row, origHeight - pullback);

            if (row.width >= galleryWidth - gutter) {
                // We have pushed out too far. Time to finish up.
                pullback = prevPullback;
                break;
            }
        }

        //
        // Final compute.
        //
        computeFromHeight(row, origHeight - pullback);
    }

    //
    // Add group headings.
    //
    let prevHeadings: string[] = [];

    if (startingRowIndex > 0) {
        //
        // Start with headings from the previous row.
        //
        prevHeadings = rows[startingRowIndex-1].headings
    }    

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

    let prevRowHeight = 0;

    if (startingRowIndex > 0) {
        //
        // Start with height of the previous row.
        //
        prevRowHeight = rows[startingRowIndex-1].offsetY + rows[startingRowIndex-1].height
    }    

    for (let rowIndex = startingRowIndex; rowIndex < rows.length; rowIndex++) {
        const row = rows[rowIndex];
        row.offsetY = prevRowHeight;
        prevRowHeight += row.height;
        layout.galleryHeight = prevRowHeight;

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