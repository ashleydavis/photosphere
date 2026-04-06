# Plan: Incremental Gallery Layout Updates

## Context
`rebuildLayout()` currently calls `computePartialLayout(undefined, sortedItems(), ...)` which rebuilds the entire layout from scratch on every `onNewItems` and `onItemsDeleted` event. With 100k assets loading in 1k batches this is O(n) per batch, i.e. O(n²) total. `computePartialLayout` was specifically designed to accept an existing layout and append new items — we need to restore that incremental behaviour. Batches are assumed to arrive in sorted order.

Additionally, the sort UI must be disabled while loading to uphold the incremental-append assumption.

## Files to modify
- `packages/user-interface/src/lib/create-layout.ts` — new `deleteFromLayout` function
- `packages/user-interface/src/test/lib/layout.test.ts` — unit tests for `deleteFromLayout`
- `packages/user-interface/src/context/gallery-layout-context.tsx` — wire incremental handlers
- `packages/user-interface/src/context/gallery-context.tsx` — expose `isLoading`
- `packages/user-interface/src/components/sidebar.tsx` — disable sort items while loading

---

## 1. New `deleteFromLayout` in `create-layout.ts`

Add alongside `computePartialLayout`:

```typescript
//
// Computes a new layout after deleting the specified assets.
// Reflows only from the earliest affected row, leaving earlier rows unchanged.
// Returns the original layout unchanged if none of the asset IDs were found.
//
export function deleteFromLayout(
    layout: IGalleryLayout,
    assetIds: string[],
    galleryWidth: number,
    targetRowHeight: number,
    getGroup: GetGroupFn,
    getHeading: GetHeadingFn
): IGalleryLayout {
    const deletedSet = new Set(assetIds);

    // Find the minimum row index containing a deleted item (scan in order, stop early)
    let minRowIndex = -1;
    outer:
    for (let rowIndex = 0; rowIndex < layout.rows.length; rowIndex++) {
        for (const item of layout.rows[rowIndex].items) {
            if (deletedSet.has(item._id)) {
                minRowIndex = rowIndex;
                break outer;
            }
        }
    }

    if (minRowIndex === -1) {
        return layout;
    }

    // Collect items from minRowIndex onwards, excluding deleted ones
    const tailItems: IGalleryItem[] = [];
    for (let rowIndex = minRowIndex; rowIndex < layout.rows.length; rowIndex++) {
        for (const item of layout.rows[rowIndex].items) {
            if (!deletedSet.has(item._id)) {
                tailItems.push(item);
            }
        }
    }

    // Truncate rows at minRowIndex; also strip any trailing heading row so
    // computePartialLayout can re-insert it correctly
    let truncateAt = minRowIndex;
    while (truncateAt > 0 && layout.rows[truncateAt - 1].type === "heading") {
        truncateAt -= 1;
    }
    const newRows = layout.rows.slice(0, truncateAt);

    if (tailItems.length === 0) {
        const lastRow = newRows.length > 0 ? newRows[newRows.length - 1] : undefined;
        return {
            rows: newRows,
            galleryHeight: lastRow ? lastRow.offsetY + lastRow.height : 0,
        };
    }

    const truncatedLayout: IGalleryLayout | undefined = newRows.length === 0
        ? undefined
        : { rows: newRows, galleryHeight: 0 };
    return computePartialLayout(truncatedLayout, tailItems, galleryWidth, targetRowHeight, getGroup, getHeading);
}
```

---

## 2. Unit tests for `deleteFromLayout` in `layout.test.ts`

Import `deleteFromLayout` alongside `computePartialLayout`. Add a `describe("deleteFromLayout", ...)` block with tests:

- deleted item not in layout → returns same layout reference unchanged
- delete only item in a single-item layout → empty layout (rows: [], galleryHeight: 0)
- delete one item from a multi-item row → remaining items reflowed into the layout
- delete item from first row when second row exists → items from second row reflow into first
- delete item from a row preceded by a heading → heading is correctly removed and re-added by reflow

Helper to build a layout: call `computePartialLayout` with known items then pass to `deleteFromLayout`.

---

## 3. `gallery-layout-context.tsx` — wire incremental handlers

### `onNewItems` subscription (replace `rebuildLayout()` call):
```typescript
const newItemsSubscription = onNewItems.subscribe(newItems => {
    const _sorting = sorting();
    setLayout(prev => {
        const startingRowIndex = (prev && prev.rows.length > 0) ? prev.rows.length - 1 : 0;
        const newLayout = computePartialLayout(prev, newItems, galleryWidth, targetRowHeight, _sorting.group, _sorting.heading);
        for (let rowIndex = startingRowIndex; rowIndex < newLayout.rows.length; rowIndex++) {
            const row = newLayout.rows[rowIndex];
            for (let itemIndex = 0; itemIndex < row.items.length; itemIndex++) {
                layoutItemsIndex.current.set(row.items[itemIndex]._id, { rowIndex, itemIndex });
            }
        }
        return newLayout;
    });
});
```

### `onItemsDeleted` subscription (replace `rebuildLayout()` call):
```typescript
const deletedItemsSubscription = onItemsDeleted.subscribe(({ assetIds }) => {
    const _sorting = sorting();
    setLayout(prev => {
        if (!prev) {
            return prev;
        }
        const newLayout = deleteFromLayout(prev, assetIds, galleryWidth, targetRowHeight, _sorting.group, _sorting.heading);
        if (newLayout === prev) {
            return prev;
        }
        const newIndex = new Map<string, { rowIndex: number; itemIndex: number }>();
        for (let rowIndex = 0; rowIndex < newLayout.rows.length; rowIndex++) {
            const row = newLayout.rows[rowIndex];
            for (let itemIndex = 0; itemIndex < row.items.length; itemIndex++) {
                newIndex.set(row.items[itemIndex]._id, { rowIndex, itemIndex });
            }
        }
        layoutItemsIndex.current = newIndex;
        return newLayout;
    });
});
```

Also add `deleteFromLayout` to the import from `"../lib/create-layout"`.

---

## 4. `gallery-context.tsx` — expose `isLoading`

- Add `isLoading: boolean` to `IGalleryContext` interface
- Destructure `isLoading` from `useGallerySource()` in `GalleryContextProvider`
- Add `isLoading` to the context value object

---

## 5. `sidebar.tsx` — disable sort while loading

- Destructure `isLoading` from `useGallery()` alongside the existing `search, setSortBy`
- In `makeFullMenu`, add `isLoading: boolean` parameter
- In the Sort menu items, guard `onClick` with `if (!isLoading)`, or omit `onClick` entirely when loading (so the item renders as non-interactive)
- Pass `isLoading` through when calling `makeFullMenu`

---

## Verification
- `bun run compile` from repo root — TypeScript must compile cleanly
- `bun run test` from repo root — all tests pass including new `deleteFromLayout` tests
