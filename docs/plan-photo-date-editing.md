# Plan: Photo Date Editing

## Context
Users need to set/edit the `photoDate` on assets in three places: the full-screen asset view, the asset info drawer, and in bulk via multi-selection. Currently `photoDate` is displayed read-only. Dates can be approximate (year/month/decade) or exact, and must also be clearable.

## Architecture

`photoDate?: string` is an optional ISO 8601 string on `IGalleryItem`. The dialog will construct ISO date strings using `dayjs` (already used throughout), setting approximate dates to the first moment of that period. Bulk updates use `updateAssets()` from `IGallerySource` (already exposed via `useGallerySource()`).

---

## Step 1: Create `SetPhotoDateDialog` component

**File:** `packages/user-interface/src/components/set-photo-date-dialog.tsx`

**Props interface `ISetPhotoDateDialogProps`:**
- `open: boolean`
- `onClose: () => void`
- `onSetDate: (date: string | undefined) => Promise<void>` — `undefined` = clear date
- `currentDate?: string` — for pre-filling inputs

**UI (MUI Joy `Modal` + `ModalDialog`):**

Dropdown to select mode (state: `dateMode`):
- `"specific"` — native `<input type="date">` (pre-filled from `currentDate`)
- `"year"` — number input (pre-filled from year of `currentDate`)
- `"month"` — two `Select`s for month (Jan–Dec) and year (pre-filled)
- `"decade"` — `Select` with options 1900s–2020s (pre-filled to nearest decade)
- `"clear"` — no additional input needed; removes the date

Buttons: Cancel | Set Date (disabled when mode requires input and it's empty/invalid)

**Date construction logic (using `dayjs`):**
- `specific` → use input value directly as ISO string: `dayjs(inputValue).toISOString()`
- `year` → `dayjs(`${year}-01-01`).toISOString()`
- `month` → `dayjs(`${year}-${monthNum}-01`).toISOString()`
- `decade` → `dayjs(`${decade}-01-01`).toISOString()`
- `clear` → `undefined`

---

## Step 2: Add date editing to `asset-info.tsx`

**File:** `packages/user-interface/src/pages/gallery/components/asset-info.tsx`

Changes:
1. Add `useState<boolean>` for `editingDate` dialog open state
2. Import and render `SetPhotoDateDialog`
3. In the existing date row: add a small edit `IconButton` (pencil icon `fa-solid fa-pen`) next to the date display, `onClick={() => setEditingDate(true)}`
4. On `onSetDate`: call `updateAsset({ photoDate: newDate })`

---

## Step 3: Add date editing to `asset-view.tsx`

**File:** `packages/user-interface/src/components/asset-view.tsx`

Changes:
1. Add `useState<boolean>` for `editingDate` dialog open state
2. Import and render `SetPhotoDateDialog`
3. Show date above the labels in the bottom-left overlay, with a pen edit button beside it
4. On `onSetDate`: call `updateAsset({ photoDate: newDate })`

---

## Step 4: Add bulk date setting to `navbar.tsx`

**File:** `packages/user-interface/src/components/navbar.tsx`

Changes:
1. Import `useGallerySource` and `SetPhotoDateDialog`
2. Add `useState<boolean>` for `setDateDialogOpen`
3. In the bulk-selection menu, add "Set date for N assets" `MenuItem`
4. On `onSetDate`: calls `updateAssets(Array.from(selectedItems).map(assetId => ({ assetId, partialAsset: { photoDate: date } })))` then `clearMultiSelection()`

---

## Critical Files

- **Created:** `packages/user-interface/src/components/set-photo-date-dialog.tsx`
- **Modified:** `packages/user-interface/src/pages/gallery/components/asset-info.tsx`
- **Modified:** `packages/user-interface/src/components/asset-view.tsx`
- **Modified:** `packages/user-interface/src/components/navbar.tsx`

## Reused Infrastructure

- `updateAsset()` from `useGalleryItem()` — single asset update
- `updateAssets()` from `useGallerySource()` — bulk update
- `dayjs` — already used throughout the project
- MUI Joy `Modal`, `ModalDialog`, `Select`, `Option`, `Input`, `Button`, `DialogTitle`, `DialogContent`, `DialogActions`
- `selectedItems: Set<string>` from `useGallery()`

---

## Verification

1. Run `bun run compile` — TypeScript must compile cleanly
2. Run `bun run test` — all existing tests must pass
3. Manual testing:
   - Open a photo in asset-view → click pen button next to date → set a specific date → confirm
   - Open asset-info drawer → click edit on date → set year-only → confirm
   - Open asset-info drawer → edit date → select "Clear date" → confirm photo becomes undated
   - Multi-select several photos → open navbar menu → "Set date for N assets" → set a decade → confirm all selected photos updated
