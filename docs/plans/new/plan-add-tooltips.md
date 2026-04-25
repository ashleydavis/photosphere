# Add Tooltips to Buttons and Interactive Elements

## Overview
Many icon-only buttons throughout the Photosphere UI lack `title` attributes, making them inaccessible and difficult to discover for new users. The existing pattern (used on star, flag, download, delete, etc.) is a plain `title="..."` prop on `IconButton` or `<button>`. This plan adds that same `title` prop to every interactive element that currently lacks one.

## Issues

## Steps

1. **navbar.tsx** – Add `title` to four buttons:
   - `<button onClick={() => setSidebarOpen(...)}` (hamburger, line 84) → `title="Toggle sidebar"`
   - `<button ... onClick={event => { setOpenSearch(true); }}` (search, line 92) → `title="Search"`
   - `<button className="w-6 text-sm" onClick={clearMultiSelection}` (clear selection, line 162) → `title="Clear selection"`
   - `<IconButton ... onClick={() => setRightSidebarOpen(true)}` (MoreVert, line 175) → `title="Open menu"`
   - `<button className="w-10 text-xl" onClick={() => { ... onCloseSearch(); }}` (close search, line 248) → `title="Close search"`

2. **asset-view.tsx** – Add `title` to three buttons:
   - Left nav `IconButton` (arrow-left, line 139) → `title="Previous"`
   - Right nav `IconButton` (arrow-right, line 152) → `title="Next"`
   - Close `IconButton` (fa-close, line 168) → `title="Close"`
   - Info `IconButton` (fa-circle-info, line 275) → `title="Asset info"`
   - Remove-label `IconButton` inside `Chip.endDecorator` (line 425) → `title="Remove label"`

3. **left-sidebar.tsx** – Add `title` to one button:
   - `<button className="mr-3 text-xl" onClick={() => setSidebarOpen(!sidebarOpen)}` (arrow-left, line 78) → `title="Close sidebar"`

4. **right-sidebar.tsx** – Add `title` to three buttons:
   - `<button className="ml-3 text-xl" onClick={() => setSidebarOpen(!sidebarOpen)}` (arrow-right, line 353) → `title="Close menu"`
   - Saved searches unsave `IconButton` (Star gold, line 474) → `title="Remove saved search"`
   - Recent searches delete `IconButton` (Delete, line 535) → `title="Remove from recent searches"`

5. **open-database-modal.tsx** – Add `title` to one button:
   - Refresh `IconButton` (line 114) → `title="Refresh"`

6. **toast-container.tsx** – Add `title` to one button:
   - Close `IconButton` (Close icon, line 40) → `title="Dismiss"`

7. **databases-page.tsx** – Add `title` to four icon buttons:
   - Refresh `IconButton` (line 282) → `title="Refresh"`
   - Open `IconButton` (FolderOpen, line 338) → `title="Open database"`
   - Share `IconButton` (IosShare, line 345) → `title="Share database"`
   - Edit `IconButton` (Edit, line 352) → `title="Edit database"`
   - Delete `IconButton` (Delete, line 359) → `title="Remove database"`

8. **secrets-page.tsx** – Add `title` to three icon buttons:
   - Refresh `IconButton` (line 340) → `title="Refresh"`
   - Share `IconButton` (IosShare, line 385) → `title="Share secret"`
   - Edit `IconButton` (Edit, line 392) → `title="Edit secret"`
   - Delete `IconButton` (Delete, line 399) → `title="Delete secret"`

9. **asset-info.tsx** – Add `title` to two buttons:
   - Close `IconButton` (fa-close, line 159) → `title="Close"`
   - Remove-label `IconButton` inside `Chip.endDecorator` in `renderLabel` (line 129) → `title="Remove label"`
   - Add-label `IconButton` (fa-square-plus, line 284) → `title="Add label"`

## Unit Tests
No unit tests are required — tooltip content is visual/HTML attribute only and is already verified by existing snapshot or rendering tests if present. No new logic is introduced.

## Smoke Tests
- Open the gallery and hover over the hamburger menu button — verify "Toggle sidebar" tooltip appears.
- Open an asset in full-screen view and hover over the navigation arrows, close button, and info button — verify tooltips appear.
- Open the left sidebar and hover the collapse arrow — verify "Close sidebar" tooltip appears.
- Open the right sidebar (MoreVert) and hover the close arrow, saved-search star, and recent-search delete buttons — verify tooltips appear.
- Open the Databases page and hover all icon buttons in the action column — verify tooltips appear.
- Open the Secrets page and hover all icon buttons in the action column — verify tooltips appear.
- Trigger a toast notification and hover the dismiss (×) button — verify "Dismiss" tooltip appears.

## Verify
- `bun run compile` from repo root passes with no TypeScript errors.
- `bun run test` from repo root passes.

## Notes
- The existing pattern throughout the codebase is `title="..."` on MUI Joy `<IconButton>` or plain `<button>`. This renders as a native browser tooltip, consistent with what is already used for star, flag, download, delete, etc. No new Tooltip component is needed.
- The `title` prop is not rendered on `<NavLink>` items or text-labelled `<Button>` components (e.g. "New database", "Add Secret") because their label already communicates intent.
- `s3-browser-modal.tsx` breadcrumb buttons were excluded — they show path-segment text labels, so tooltips are not needed there.
