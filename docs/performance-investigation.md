# Gallery Loading Performance Investigation

## The Problem

The gallery renders at ~2fps while loading a database of 100k assets. It should stay close to 60fps during loading — assets should appear progressively while the UI remains responsive.

## How to Measure FPS

FPS logging is built in. From the repo root directory run the app with:

```
bun run dev:fps
```

This sets `FPS_LOGGING=1`, which causes `main.ts` to write one CSV row per second to `/tmp/photosphere-fps.csv` (columns: `timestamp`, `fps`). The database opens automatically. Let it run for ~2 minutes, kill it, then compute the average:

```
awk -F, 'NR>1 {sum+=$2; count++} END {print "avg fps:", sum/count}' /tmp/photosphere-fps.csv
```

FPS is measured in `fps.tsx` using a `requestAnimationFrame` loop and sent to the main process via `window.electronAPI.sendFps(fps)`.

---

## Phase 1: Root Cause — IPC Properties Field

### Proven Root Cause

**The `properties` field (parsed EXIF/metadata) in `IGalleryItem` creates massive Electron IPC payloads that block the renderer's main thread during structured clone deserialization.**

### Evidence Table

| Experiment | IPC Payload | FPS | Max Jank |
|---|---|---|---|
| Baseline | Full items (micro + properties) | 4–9fps | 3257ms |
| Remove setTime only | Full items | 9fps | — |
| Remove TanStack Virtual | Full items | 11fps | — |
| Remove ALL React state updates | Full items | 9fps | — |
| Remove O(n log n) sort + buildIndex | Full items | 9fps | — |
| IPC callback completely disabled | Full items | 4–9fps | 3257ms |
| **Empty batch `{}`** | Empty objects | **60fps** | 55ms |
| Micro-only `{_id, micro}` | Small base64 strings | 60fps | 47ms |
| **Properties-only `{_id, properties}`** | EXIF data | **4–9fps** | 2625ms |

### Mechanism

1. The database worker sends ~800-item pages via IPC: worker → main process → renderer
2. The `properties` field contains large parsed EXIF objects. At 800 items/batch, this creates **megabytes of nested object data** per IPC message
3. Electron's **structured clone deserialization** of this payload runs on the **renderer's main thread**, blocking it for **hundreds to thousands of milliseconds per batch** — before any JavaScript callback fires
4. As the sort-index B-tree page cache warms up, later pages arrive much faster (17ms intervals vs 260ms cold). Multiple IPC messages pile up in Chromium's IPC queue and are all drained before yielding to `requestAnimationFrame`, causing **snowballing multi-second freezes** (up to 3.7 seconds in one burst)

A jank detector (setInterval at 4ms, logs gaps > 20ms) confirmed main-thread blocks of:
55ms → 446ms → 800ms → 1411ms → 1948ms → **3706ms** → 1803ms across a single loading run.

### Fix Applied

Whitelist only the fields needed for gallery display in `packages/api/src/lib/load-assets.worker.ts`. Strip `properties` (EXIF data) — it is the primary IPC blocking culprit. `properties` can be fetched on demand when a detail view opens.

**Result after fix: 58fps average, loading dip reduced to 2–3 seconds at 9fps.** Target is no seconds below 15fps.

---

## Phase 2: Remaining Dip — Still Under Investigation

After stripping `properties`, a ~2–3 second dip to 9–13fps remains during the B-tree cache warmup phase (when IPC batches arrive at maximum rate, ~17ms intervals).

### What Has Been Ruled Out

These have all been tried and confirmed NOT to be the remaining cause:

| Experiment | Result | Conclusion |
|---|---|---|
| Strip `micro` field from IPC | Still 11–13fps dip | `micro` is a minor contributor (~2fps), not primary |
| Skip all rendering (no setTime, no setLayout) | **60fps, zero dips** | JS processing in IPC callbacks is fast enough — render IS the bottleneck |
| Skip `computePartialLayout`, call setLayout no-op | 60fps | layout computation alone is NOT the bottleneck |
| Compute layout into ref, never render | 60fps | layout computation (even with growing prev) is NOT the bottleneck |
| computePartialLayout inside `setLayout` functional updater | ~9fps dip | React double-invokes functional updaters — MOVED COMPUTATION OUT |
| Replace O(n log n) `applySort` with O(k) incremental append | 10fps (minor improvement) | sort was a contributor but not primary |
| Replace O(n) `buildItemsIndex` with O(k) incremental | 10fps (no improvement) | index rebuild was not the bottleneck |
| Replace `concat` with `push` for item arrays | 12fps (minor improvement) | O(n) array allocation contributed slightly |
| Move layout to ref, drive renders from layout-context setTime | 13fps (minor improvement) | Separates render from IPC callback, helps a little |
| Move layout to ref, drive renders from gallery-context setTime | 12fps | Same as above, no meaningful difference |
| `React.memo` on `GalleryRow` + stable `onItemClick` via `useCallback` | 12fps | Memoized rows help slightly but can't prevent context-driven re-renders |
| `React.memo` on `GalleryLayout` | 12fps | Context subscription (`useGalleryLayout`) still causes re-renders, memo has no effect |
| rAF-throttle `setTime` in layout-context (batch renders to 60fps) | 12fps | Throttling reduces render count but each render is more expensive (larger count jump) |
| Per-batch `setTime` (no throttle) | 10–12fps | More renders but smaller count increments — similar net cost |
| Skip all `computePartialLayout` phases except item loop (stretch/pullback/headings/offsets all `if (false)`) | 11fps | Those phases are NOT the bottleneck |
| Replace `getGroup` with `() => []` (skip dayjs date parsing) | 11fps | `getGroup`/dayjs is NOT the bottleneck |
| Skip `computePartialLayout` entirely, still fire rAF `setTime` | **60fps** | Bottleneck requires BOTH new rows being added AND renders firing |
| Return before item loop in `computePartialLayout`, still fire rAF `setTime` | **60fps** | Confirms: item loop computation is NOT the bottleneck — rendering new rows is |
| Timing CSV for `computePartialLayout` and `_onNewItems` | 1–4ms and 0–0.5ms, flat throughout loading | Both are O(k new items) — the cost is NOT growing with layout size |
| Simplify to 1 item per row (EXP-M) | Still ~9fps dip | Row count alone is NOT the bottleneck (21k rows vs normal ~3k made no difference) |
| Freeze TanStack Virtual at count=0 while `setTime` still fires (EXP-N) | Still ~9fps dip | TanStack Virtual O(n) `getMeasurements` is NOT the bottleneck |
| Disable `setTime` entirely + count=0 (EXP-O) | **60fps** | React re-renders triggered by `setTime` ARE the cause — something in the render path is O(n) |
| Add `!isLoading` guards to sidebar `buildNavMenu`/`determineYears`/`determineLocations` (EXP-P) | **60fps solid throughout loading** | **ROOT CAUSE CONFIRMED: sidebar O(n) scans** |

### Confirmed Root Cause

`setTime(Date.now())` fires in `gallery-context` on every IPC batch, triggering a React re-render of all `useGallery()` subscribers — including the **sidebar**.

The sidebar runs three O(n) scans on every render with no memoization:

- `buildNavMenu(layout)` — `layout.rows.filter(row => row.type === "heading")` — O(n rows)
- `determineYears(layout)` — iterates all rows × all items — O(n items)
- `determineLocations(layout)` — iterates all rows × all items — O(n items)

As the layout grows to ~21,000 rows during loading of 100k assets, each render takes progressively longer, dropping FPS to 9. The layout computation itself (`computePartialLayout`) is flat at 1–4ms per batch — it was never the problem.

---

## Current State of the Code (Applied Fixes)

### Fix 1: Strip `properties` from IPC batch
**File:** `packages/api/src/lib/load-assets.worker.ts`  
Whitelist of fields sent per batch — `properties` (EXIF) excluded.

### Fix 2: No sort during loading
**File:** `packages/user-interface/src/context/gallery-context.tsx`, `_onNewItems()`  
Assets arrive in sorted order from the database. Replaced O(n log n) `applySort` + O(n) `buildItemsIndex` with O(k) incremental append + incremental index update. `applySort` is still called by `setSortBy()` when the user changes sort order after loading.

### Fix 3: Layout as a ref
**File:** `packages/user-interface/src/context/gallery-layout-context.tsx`  
`layout` state replaced by `layoutRef` (a `useRef`). `computePartialLayout` writes into the ref synchronously in the `onNewItems` callback. A `setTime` call (driving a re-render) is issued to flush the ref to consumers. This decouples computation from React's functional updater invocation (eliminating double-computation in dev mode).

~~**Fix 4: Memoized row component**~~ *(tried and reverted — didn't help enough)*

~~**Fix 5: Stable `onItemClick` callback**~~ *(tried and reverted — didn't help enough)*

### Fix 4: Skip sidebar O(n) scans during loading
**File:** `packages/user-interface/src/components/sidebar.tsx`  
Added `!isLoading` guards to the three O(n) layout scans in the sidebar component. When loading, all three return `[]` instantly. When loading completes, they run once against the final layout.

```typescript
const navMenu = (layout && !isLoading) ? buildNavMenu(layout, position => {
    scrollTo(position);
    setSidebarOpen(false);
}) : [];
const years = (layout && !isLoading) ? determineYears(layout) : [];
const locations = (layout && !isLoading) ? determineLocations(layout) : [];
```

**Result: 60fps solid throughout loading. Investigation complete.**
